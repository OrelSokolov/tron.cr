# Tron::Protobuf::TransactionRawSerializer — 1:1 к tron.rb 1.2.4
# (lib/tron/protobuf/transaction_raw_serializer.rb): сериализация raw_data
# транзакции в protobuf wire format для подписи.

require "json"

module Tron
  module Protobuf
    class TransactionRawSerializer
      REF_BLOCK_BYTES = 1
      REF_BLOCK_NUM   = 2
      REF_BLOCK_HASH  = 3
      EXPIRATION      = 4
      AUTHS           = 5 # authority
      DATA            = 6
      CONTRACT        = 7
      SCRIPTS         = 8
      FEE_LIMIT       = 9

      CONTRACT_TYPE      = 1
      CONTRACT_PARAMETER = 2
      CONTRACT_PROVIDER  = 3

      def self.serialize(transaction : JSON::Any) : Bytes
        raw_data = transaction["raw_data"]
        result = Bytes.empty

        if raw_data["ref_block_bytes"]?
          result += encode_field(REF_BLOCK_BYTES, :bytes,
            convert_hex_to_bytes(raw_data["ref_block_bytes"].as_s))
        end

        if raw_data["ref_block_num"]?
          result += encode_field(REF_BLOCK_NUM, :varint, raw_data["ref_block_num"].as_i64)
        end

        if raw_data["ref_block_hash"]?
          result += encode_field(REF_BLOCK_HASH, :bytes,
            convert_hex_to_bytes(raw_data["ref_block_hash"].as_s))
        end

        if raw_data["expiration"]?
          result += encode_field(EXPIRATION, :varint, raw_data["expiration"].as_i64)
        end

        # timestamp — номер поля в tron.rb принят равным 10
        if raw_data["timestamp"]?
          result += encode_field(10, :varint, raw_data["timestamp"].as_i64)
        end

        if raw_data["fee_limit"]?
          result += encode_field(FEE_LIMIT, :varint, raw_data["fee_limit"].as_i64)
        end

        if raw_data["contract"]?
          contract_data = raw_data["contract"]
          if contract_data.as_a?
            contract_data.as_a.each do |contract|
              result += encode_field(CONTRACT, :embedded_message, serialize_contract(contract))
            end
          else
            result += encode_field(CONTRACT, :embedded_message, serialize_contract(contract_data))
          end
        end

        if raw_data["data"]?
          result += encode_field(DATA, :bytes,
            convert_hex_to_bytes(raw_data["data"].as_s))
        end

        result
      end

      def self.encode_field(field_number : Int32, field_type : Symbol,
                            value : Int64 | Int32 | BigInt) : Bytes
        # varint-значение (или length-delimited-обёртка вокруг числа не используется)
        if field_type == :varint
          encode_varint((field_number << 3) | wire_type(:varint)) + encode_varint(value)
        else
          encode_field(field_number, field_type, value.to_s.to_slice)
        end
      end

      def self.encode_field(field_number : Int32, field_type : Symbol, value : Bytes) : Bytes
        key = (field_number << 3) | wire_type(field_type)
        varint_bytes = encode_varint(key)
        varint_bytes + encode_varint(value.size) + value
      end

      def self.encode_field(field_number : Int32, field_type : Symbol, value : String) : Bytes
        encode_field(field_number, field_type, value.to_slice)
      end

      def self.wire_type(field_type : Symbol) : Int32
        case field_type
        when :varint then 0
        else              2 # bytes / embedded_message / прочее
        end
      end

      def self.encode_varint(value : Int64 | Int32 | BigInt) : Bytes
        v = value.to_big_i
        result = Array(UInt8).new
        loop do
          byte = (v & 0x7F).to_u8
          v >>= 7
          if v == 0
            result << byte
            break
          else
            result << (byte | 0x80).to_u8
          end
        end
        Bytes.new(result.to_unsafe, result.size).dup
      end

      def self.serialize_contract(contract : JSON::Any) : Bytes
        result = Bytes.empty

        if contract["type"]?
          type_value = contract_type_to_int(contract["type"].as_s)
          result += encode_field(CONTRACT_TYPE, :varint, type_value)
        end

        if contract["parameter"]?
          param_bytes = serialize_contract_parameter(contract["parameter"])
          result += encode_field(CONTRACT_PARAMETER, :embedded_message, param_bytes)
        end

        if contract["provider"]?
          result += encode_field(CONTRACT_PROVIDER, :bytes,
            convert_hex_to_bytes(contract["provider"].as_s))
        end

        result
      end

      def self.serialize_contract_parameter(parameter : JSON::Any) : Bytes
        result = Bytes.empty

        if (value_any = parameter["value"]?) && (value_hash = value_any.as_h?)
          # упрощённая (как в tron.rb) сериализация полей значения контракта
          value_hash.each do |field_name, field_value|
            field_number = case field_name
                           when "owner_address"     then 1
                           when "contract_address"  then 2
                           when "data", "function_selector" then 3
                           when "call_value"        then 4
                           when "fee_limit"         then 5
                           else                          1
                           end

            if (s = field_value.as_s?)
              result += encode_field(field_number, :bytes, convert_hex_to_bytes(s))
            elsif (i = field_value.as_i64?)
              result += encode_field(field_number, :varint, i)
            else
              result += encode_field(field_number, :bytes, field_value.to_s.to_slice)
            end
          end
        end

        type_url = if (tu = parameter["type_url"]?.try &.as_s?)
                     tu
                   else
                     "type.googleapis.com/protocol.#{parameter["type"]?.try &.as_s? || "TriggerSmartContract"}"
                   end
        # как в tron.rb: encode_field(1, :string, …) идёт в else-ветку —
        # ключ + сырые байты, БЕЗ length-префикса
        result += encode_varint((1 << 3) | wire_type(:bytes)) + type_url.to_slice

        result
      end

      CONTRACT_TYPE_MAP = {
        "AccountCreateContract"          => 0,
        "TransferContract"               => 1,
        "TransferAssetContract"          => 2,
        "VoteAssetContract"              => 3,
        "VoteWitnessContract"            => 4,
        "WitnessCreateContract"          => 5,
        "AssetIssueContract"             => 6,
        "WitnessUpdateContract"          => 7,
        "ParticipateAssetIssueContract"  => 8,
        "AccountUpdateContract"          => 9,
        "FreezeBalanceContract"          => 10,
        "UnfreezeBalanceContract"        => 11,
        "WithdrawBalanceContract"        => 12,
        "UnfreezeAssetContract"          => 13,
        "UpdateAssetContract"            => 14,
        "ProposalCreateContract"         => 15,
        "ProposalApproveContract"        => 16,
        "ProposalDeleteContract"         => 17,
        "SetAccountIdContract"           => 18,
        "CustomContract"                 => 19,
        "CreateSmartContract"            => 30,
        "TriggerSmartContract"           => 31,
        "GetContract"                    => 32,
        "UpdateSettingContract"          => 33,
        "ExchangeCreateContract"         => 41,
        "ExchangeInjectContract"         => 42,
        "ExchangeWithdrawContract"       => 43,
        "ExchangeTransactionContract"    => 44,
        "UpdateEnergyLimitContract"      => 45,
        "AccountPermissionUpdateContract" => 46,
      } of String => Int32

      def self.contract_type_to_int(type_name : String) : Int32
        CONTRACT_TYPE_MAP[type_name]? || 0
      end

      def self.convert_hex_to_bytes(hex_string : String) : Bytes
        hex = hex_string
        hex = hex[2..] if hex.starts_with?("0x") || hex.starts_with?("0X")
        hex = "0" + hex if hex.size.odd?
        Tron::Crypto.hex_to_bin(hex)
      end
    end
  end
end

require "../crypto/base58"
