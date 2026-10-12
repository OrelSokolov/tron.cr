# Tron::Abi::Function — 1:1 к tron.rb 1.2.4 (lib/tron/abi/function.rb).

require "json"
require "../crypto/keccak"
require "./type"
require "./encoder"
require "./decoder"
require "./util"

module Tron
  module Abi
    class Function
      # Параметр функции (вход или выход).
      struct Param
        getter type : String
        getter name : String?

        def initialize(@type, @name = nil)
        end

        def self.from_json(any : JSON::Any) : Param
          # Квирк 1:1 tron.rb: from_abi читает input[:type] СИМВОЛЬНЫМ ключом,
          # а JSON-хеши строковые → всегда nil → пустой тип в сигнатуре.
          Param.new("", any["name"]?.try &.as_s)
        end
      end

      getter name : String
      getter inputs : Array(Param)
      getter outputs : Array(Param)
      getter? constant : Bool
      getter? payable : Bool
      getter signature : String
      getter method_id : String

      def initialize(@name : String, inputs : Array(Param) = [] of Param,
                     outputs : Array(Param) = [] of Param, constant = false, payable = false)
        @inputs = inputs
        @outputs = outputs
        @constant = constant
        @payable = payable
        @signature = generate_signature
        @method_id = generate_method_id
      end

      def generate_signature : String
        param_types = @inputs.map(&.type).join(",")
        "#{@name}(#{param_types})"
      end

      # method id: первые 4 байта keccak256 сигнатуры, hex.
      def generate_method_id : String
        hash = Crypto.keccak256(@signature)
        Util.bin_to_hex(hash[0, 4])
      end

      def encode_input(parameters : Array(Value)) : String
        unless parameters.size == @inputs.size
          raise ArgumentError.new("Expected #{@inputs.size} parameters, got #{parameters.size}")
        end

        encoded_params = Bytes.empty
        parameters.each_with_index do |param, idx|
          type = Type.parse(@inputs[idx].type)
          encoded_params += Encoder.type(type, param)
        end

        Util.bin_to_hex(Util.hex_to_bin(@method_id) + encoded_params)
      end

      def decode_output(data : String) : Array(Value)
        raw_data = data.starts_with?("0x") ? data[2..] : data

        results = [] of Value
        offset = 0

        @outputs.each do |output|
          type = Type.parse(output.type)
          if type.dynamic?
            offset_ptr = raw_data[offset, 64]
            actual_offset = Util.deserialize_big_endian_to_int(Util.hex_to_bin(offset_ptr)).to_i
            decoded_value = Decoder.type(type, Util.hex_to_bin(raw_data[actual_offset * 2..]))
            results << decoded_value
            offset += 64
          else
            size = (type.size || 32) * 2 # байты → hex-символы
            decoded_value = Decoder.type(type, Util.hex_to_bin(raw_data[offset, size]))
            results << decoded_value
            offset += size
          end
        end

        results
      end

      def self.from_abi(abi_def : JSON::Any) : Function
        unless abi_def["type"]?.try(&.as_s?) == "function"
          raise ArgumentError.new("Not a function definition")
        end

        Function.new(
          name: abi_def["name"].as_s,
          inputs: (abi_def["inputs"]? || JSON::Any.new([] of JSON::Any)).as_a.map { |i| Param.from_json(i) },
          outputs: (abi_def["outputs"]? || JSON::Any.new([] of JSON::Any)).as_a.map { |i| Param.from_json(i) },
          constant: abi_def["constant"]?.try(&.as_bool?) || false,
          payable: abi_def["payable"]?.try(&.as_bool?) || false
        )
      end

      # method id из сигнатуры вида "transfer(address,uint256)".
      def self.signature(sig : String) : String
        hash = Crypto.keccak256(sig)
        Util.bin_to_hex(hash[0, 4])
      end
    end
  end
end
