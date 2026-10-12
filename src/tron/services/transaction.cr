# Tron::Services::Transaction — 1:1 к tron.rb 1.2.4
# (lib/tron/services/transaction.rb): подпись и броадкаст транзакций.
#
# ВАЖНО (как в tron.rb): TRON использует SHA256 для хеша транзакции,
# txID от TronGrid — уже готовый хеш protobuf-сериализованного raw_data.

require "json"
require "../utils/http"
require "../key"

module Tron
  module Services
    class Transaction
      def initialize(@configuration : Configuration)
        @base_url = @configuration.base_url
      end

      def sign_and_broadcast(transaction : JSON::Any, private_key : String,
                             local_signing : Bool = true) : JSON::Any
        signed_tx = local_signing ? sign_transaction_locally(transaction, private_key) : sign_transaction_via_api(transaction, private_key)

        broadcast_transaction(signed_tx)
      end

      def get_transaction(tx_id : String) : JSON::Any
        endpoint = "#{@base_url}/wallet/gettransactionbyid"
        payload = {"value" => JSON::Any.new(tx_id)} of String => JSON::Any

        Utils::HTTP.post(endpoint, payload)
      end

      def get_transaction_info(tx_id : String) : JSON::Any
        endpoint = "#{@base_url}/wallet/gettransactioninfobyid"
        payload = {"value" => JSON::Any.new(tx_id)} of String => JSON::Any

        Utils::HTTP.post(endpoint, payload)
      end

      # Ожидает подтверждения транзакции (опрос каждые 2 секунды).
      def wait_for_transaction(tx_id : String, max_attempts : Int32 = 15) : JSON::Any
        print "Waiting for transaction: #{tx_id}"

        max_attempts.times do |i|
          sleep 2
          print "."

          begin
            tx_info = get_transaction(tx_id)

            if tx_info.as_h? && (ret = tx_info["ret"]?) && ret.as_a? && !ret.as_a.empty?
              result = ret.as_a.first["contractRet"]?.try &.as_s?

              if result == "SUCCESS"
                puts "\n✓ Transaction confirmed"
                return tx_info
              end

              if result == "REVERT"
                puts "\n❌ Transaction reverted"

                error_message = extract_revert_reason(tx_id)

                raise "Transaction failed: #{error_message}"
              end
            end
          rescue e : Exception
            raise e if e.message.try &.starts_with?("Transaction failed:")
            next if i < max_attempts - 1
            raise e
          end
        end

        raise "Transaction timeout"
      end

      private def extract_revert_reason(tx_id : String) : String
        tx_detail = get_transaction_info(tx_id)

        # contractResult содержит ABI-encoded причину revert
        if tx_detail.as_h? && (cr = tx_detail["contractResult"]?) && cr.as_a? && !cr.as_a.empty?
          contract_result = cr.as_a.first.as_s?

          if contract_result && contract_result.starts_with?("08c379a0")
            begin
              # Error(string): селектор (8 hex) + offset (64) + длина (64) + данные
              data = contract_result[8 + 64..]

              length_hex = data[0, 64]
              length = length_hex.to_i64(16)

              string_hex = data[64, length * 2]

              error_message = String.new(Tron::Crypto.hex_to_bin(string_hex))

              return error_message unless error_message.empty?
            rescue e : Exception
              # при ошибке декодирования — идём дальше
            end
          end
        end

        # resMessage: hex-кодированная строка ошибки
        if tx_detail.as_h? && (rm = tx_detail["resMessage"]?) && (error_hex = rm.as_s?)
          begin
            error_message = String.new(Tron::Crypto.hex_to_bin(error_hex))
            error_message = error_message.gsub(/[\x00-\x1f\x7f]/, "").strip

            return error_message unless error_message.empty?
          rescue e : Exception
            # идём дальше
          end
        end

        "REVERT opcode executed"
      end

      # Локальная подпись: приватный ключ не покидает машину.
      private def sign_transaction_locally(transaction : JSON::Any, private_key : String) : JSON::Any
        key = Key.new(private_key)

        unless transaction["txID"]?
          raise ArgumentError.new("Transaction must have 'txID' field. Create transaction via TronGrid API first.")
        end

        # txID — SHA256 от protobuf-сериализованного raw_data
        tx_hash = Tron::Crypto.hex_to_bin(transaction["txID"].as_s)

        signature = key.sign(tx_hash)

        transaction.as_h["signature"] = JSON::Any.new([JSON::Any.new(signature)] of JSON::Any)

        transaction
      end

      # Подпись через API (legacy).
      private def sign_transaction_via_api(transaction : JSON::Any, private_key : String) : JSON::Any
        endpoint = "#{@base_url}/wallet/gettransactionsign"
        payload = {
          "transaction" => transaction,
          "private_key" => JSON::Any.new(private_key),
        } of String => JSON::Any

        Utils::HTTP.post(endpoint, payload)
      end

      private def broadcast_transaction(signed_transaction : JSON::Any) : JSON::Any
        endpoint = "#{@base_url}/wallet/broadcasttransaction"

        response = Utils::HTTP.post(endpoint, signed_transaction.as_h)

        unless truthy?(response["result"]?)
          error_message = any_to_s(response["Error"]?) || any_to_s(response["error"]?) ||
                          any_to_s(response["message"]?) || "Unknown error"

          error_details = ["❌ Transaction broadcast failed: #{error_message}"]

          if (code = response["code"]?) && code.as_s?
            error_details << "   Error code: #{code.as_s}"
          end

          tx_id = any_to_s(response["txid"]?) || any_to_s(response["txID"]?)
          if tx_id
            error_details << "   Transaction ID: #{tx_id}"
          end

          error_details << "   Full response: #{response.inspect}"

          raise error_details.join("\n")
        end

        response
      end

      private def truthy?(v : JSON::Any?) : Bool
        return false if v.nil?
        return false if (b = v.as_bool?) && !b
        true
      end

      private def any_to_s(v : JSON::Any?) : String?
        return nil if v.nil?
        v.as_s?
      end
    end
  end
end
