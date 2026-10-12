# Tron::Abi — 1:1 к tron.rb 1.2.4 (lib/tron/abi.rb): encode/decode ABI-значений,
# кодирование вызовов функций, solidity packed encoding.

require "json"
require "big"
require "./crypto/keccak"
require "./abi/type"
require "./abi/encoder"
require "./abi/decoder"
require "./abi/function"
require "./abi/event"
require "./abi/packed"

module Tron
  module Abi
    class Error < Exception
    end

    class EncodingError < Error
    end

    class DecodingError < Error
    end

    class ValueOutOfBounds < Error
    end

    # Значение ABI-аргумента (аналог duck typing Ruby-версии).
    alias Value = Nil | Bool | Int32 | Int64 | BigInt | Float64 | String | Bytes |
                  Array(Value) | Hash(String, Value)

    # Кодирование списка значений → hex (как Abi.encode в tron.rb).
    def self.encode(types : Array(String), values : Array(Value)) : String
      parsed_types = types.map { |t| Type.parse(t) }

      static_parts = [] of Bytes?
      dynamic_parts = [] of Bytes
      dynamic_offsets = [] of Int32
      offset_index = 0

      parsed_types.each_with_index do |type, i|
        if type.dynamic?
          static_parts << nil # плейсхолдер под смещение
          dynamic_parts << Encoder.type(type, values[i])
          dynamic_offsets << dynamic_parts.size - 1
          offset_index += 1
        else
          static_parts << Encoder.type(type, values[i])
        end
      end

      static_size = parsed_types.size * 32 # слоты всех параметров
      dynamic_offset = static_size

      placeholders_replaced = 0
      static_parts.map! do |part|
        if part.nil?
          offset_value = dynamic_offset
          dynamic_part_idx = dynamic_offsets[placeholders_replaced]
          dynamic_offset += dynamic_parts[dynamic_part_idx].size
          placeholders_replaced += 1
          Encoder.type(Type.size_type, offset_value)
        else
          part
        end
      end

      result_binary = Util.concat(static_parts.map { |p| p || Bytes.empty }) + Util.concat(dynamic_parts)
      Util.bin_to_hex(result_binary)
    end

    # Кодирование вызова функции: селектор (4 байта keccak256 сигнатуры) + параметры.
    def self.encode_function_call(signature : String, parameters : Array(Value) = [] of Value) : String
      match = /^(\w+)\((.*)\)$/.match(signature)
      raise ArgumentError.new("Invalid function signature: #{signature}") unless match

      param_types_str = match[2].not_nil!
      param_types = param_types_str.empty? ? [] of String : split_function_params(param_types_str)

      hash = Crypto.keccak256(signature)
      selector = Util.bin_to_hex(hash[0, 4])

      return selector if parameters.empty?

      selector + encode(param_types, parameters)
    end

    # Разбиение типов параметров по запятым с учётом вложенных tuple.
    def self.split_function_params(params_str : String) : Array(String)
      types = [] of String
      depth = 0
      current = ""

      params_str.each_char do |ch|
        case ch
        when '(' then depth += 1; current += ch
        when ')' then depth -= 1; current += ch
        when ','
          if depth.zero?
            types << current.strip
            current = ""
          else
            current += ch
          end
        else current += ch
        end
      end

      types << current.strip unless current.empty?
      types
    end

    # Solidity packed encoding (без паддинга до 32 байт) → binary.
    def self.solidity_packed(types : Array(String), values : Array(Value)) : Bytes
      unless types.size == values.size
        raise ArgumentError.new("Types and values must be the same length")
      end

      result = Bytes.empty
      types.zip(values) do |type, value|
        result += Packed::Encoder.type(type, value)
      end
      result
    end

    # Декодирование выхода контрактного вызова (одиночный тип).
    def self.decode_output(type_str : String, hex_data : String) : Value
      decode([type_str], hex_data).first
    end

    # Декодирование списка значений из hex.
    def self.decode(types : Array(String), hex_data : String) : Array(Value)
      data = Util.hex_to_bin(hex_data)
      parsed_types = types.map { |t| Type.parse(t) }

      results = [] of Value
      static_offset = 0

      parsed_types.each do |type|
        if type.dynamic?
          if data.size < static_offset + 32
            raise DecodingError.new("Insufficient data for dynamic type offset")
          end
          offset_value = Util.deserialize_big_endian_to_int(data[static_offset, 32]).to_i

          if data.size < offset_value + 32
            raise DecodingError.new("Insufficient data for dynamic type at offset #{offset_value}")
          end

          data_length = Util.deserialize_big_endian_to_int(data[offset_value, 32]).to_i

          if type.base_type.in?("string", "bytes") && type.sub_type.empty? && type.dimensions.empty?
            total_size = 32 + Util.ceil32(data_length)
          elsif !type.dimensions.empty?
            nested_type = type.nested_sub
            if nested_type.dynamic?
              param_data = data[offset_value..]
              results << Decoder.type(type, param_data)
              static_offset += 32
              next
            else
              total_size = 32 + (nested_type.size || 32) * data_length
            end
          else
            total_size = 32 + Util.ceil32(data_length)
          end

          if data.size < offset_value + total_size
            raise DecodingError.new("Insufficient data for dynamic type content")
          end

          param_data = data[offset_value, total_size]
          results << Decoder.type(type, param_data)
          static_offset += 32
        else
          size = type.size
          if size
            if data.size < static_offset + size
              raise DecodingError.new("Insufficient data for static type")
            end
            results << Decoder.type(type, data[static_offset, size])
            static_offset += size
          else
            raise DecodingError.new("Cannot decode static type without size")
          end
        end
      end

      results
    end
  end
end

require "./abi/util"
require "./utils/address"
require "./key"
