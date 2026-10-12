# Tron::Abi::Event — 1:1 к tron.rb 1.2.4 (lib/tron/abi/event.rb).

require "json"
require "../crypto/keccak"
require "./type"
require "./encoder"
require "./decoder"
require "./util"

module Tron
  module Abi
    class Event
      struct Param
        getter type : String
        getter name : String?
        getter? indexed : Bool

        def initialize(@type, @name = nil, @indexed = false)
        end
      end

      getter name : String
      getter inputs : Array(Param)
      getter? anonymous : Bool
      getter signature : String
      getter topic_hash : String

      def initialize(@name : String, inputs : Array(Param) = [] of Param, anonymous = false)
        @inputs = inputs
        @anonymous = anonymous
        @signature = generate_signature
        @topic_hash = generate_topic_hash
      end

      def generate_signature : String
        param_types = @inputs.map(&.type).join(",")
        "#{@name}(#{param_types})"
      end

      # topic hash: keccak256 сигнатуры, hex.
      def generate_topic_hash : String
        Crypto.keccak256(@signature).hexstring
      end

      # Декодирование данных лога: topics (indexed) + data-секция.
      def decode_log(topics : Array(String), data : String) : Hash(String, Value)
        result_params = [] of Value

        raw_data = data.starts_with?("0x") ? data[2..] : data
        raw_topics = topics.map { |t| t.starts_with?("0x") ? t[2..] : t }

        topic_idx = @anonymous ? 0 : 1 # первый topic — hash сигнатуры
        data_offset = 0

        @inputs.each do |input|
          type = Type.parse(input.type)

          if input.indexed?
            if topic_idx < raw_topics.size
              topic_data = raw_topics[topic_idx]
              decoded_value : Value = if type.dynamic?
                                        # для динамических типов в topic лежит hash
                                        topic_data
                                      else
                                        Decoder.type(type, Util.hex_to_bin(topic_data))
                                      end
              result_params << ({"name" => input.name, "type" => input.type,
                                 "value" => decoded_value, "indexed" => true} of String => Value)
              topic_idx += 1
            end
          elsif type.dynamic?
            offset_ptr = raw_data[data_offset, 64]
            actual_offset = Util.deserialize_big_endian_to_int(Util.hex_to_bin(offset_ptr)).to_i
            decoded_value = Decoder.type(type, Util.hex_to_bin(raw_data[actual_offset * 2..]))
            result_params << ({"name" => input.name, "type" => input.type,
                               "value" => decoded_value, "indexed" => false} of String => Value)
            data_offset += 64
          else
            size = (type.size || 32) * 2 # байты → hex-символы
            decoded_value = Decoder.type(type, Util.hex_to_bin(raw_data[data_offset, size]))
            result_params << ({"name" => input.name, "type" => input.type,
                               "value" => decoded_value, "indexed" => false} of String => Value)
            data_offset += size
          end
        end

        {"name" => @name, "params" => result_params} of String => Value
      end

      def self.from_abi(abi_def : JSON::Any) : Event
        unless abi_def["type"]?.try(&.as_s?) == "event"
          raise ArgumentError.new("Not an event definition")
        end

        inputs = (abi_def["inputs"]? || JSON::Any.new([] of JSON::Any)).as_a.map do |i|
          Param.new(i["type"].as_s, i["name"]?.try(&.as_s?),
                    i["indexed"]?.try(&.as_bool?) || false)
        end

        Event.new(
          name: abi_def["name"].as_s,
          inputs: inputs,
          anonymous: abi_def["anonymous"]?.try(&.as_bool?) || false
        )
      end

      def self.signature(sig : String) : String
        Crypto.keccak256(sig).hexstring
      end
    end
  end
end
