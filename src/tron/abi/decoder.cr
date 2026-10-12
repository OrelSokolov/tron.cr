# Tron::Abi::Decoder — 1:1 к tron.rb 1.2.4 (lib/tron/abi/decoder.rb).

require "./util"
require "./type"
require "../utils/address"

module Tron
  module Abi
    module Decoder
      # Декодирует значение (статическое или динамическое) из binary.
      def self.type(type : Type, arg : Bytes) : Value
        if type.base_type.in?("string", "bytes") && type.sub_type.empty?
          if type.dimensions.empty?
            l = Util.deserialize_big_endian_to_int(arg[0, 32])
            data = arg[32..]
            unless data.size == Util.ceil32(l)
              raise DecodingError.new("Wrong data size for string/bytes object")
            end
            if type.base_type == "string"
              String.new(data[0, l.to_i])
            else
              data[0, l.to_i]
            end
          else
            # массив string/bytes
            l = Util.deserialize_big_endian_to_int(arg[0, 32]).to_i
            unless arg.size >= 32 + 32 * l
              raise DecodingError.new("Wrong data size for dynamic array")
            end
            elements = Array(Value).new
            (1..l).each do |i|
              pointer = Util.deserialize_big_endian_to_int(arg[i * 32, 32]).to_i
              if pointer < 32 * l || pointer > arg.size - 64
                raise DecodingError.new("Offset out of bounds")
              end
              data_l = Util.deserialize_big_endian_to_int(arg[32 + pointer, 32]).to_i
              if pointer + 32 + Util.ceil32(data_l) > arg.size
                raise DecodingError.new("Offset out of bounds")
              end
              elements << self.type(Type.parse(type.base_type), arg[pointer + 32, Util.ceil32(data_l) + 32])
            end
            elements
          end
        elsif type.base_type == "tuple" && type.dimensions.empty?
          comps = type.components
          raise DecodingError.new("Cannot decode tuples without known components") if comps.nil?
          offset = 0
          result = [] of Value
          comps.each_with_index do |c, i|
            if c.dynamic?
              pointer = Util.deserialize_big_endian_to_int(arg[offset, 32]).to_i
              next_offset = if i + 1 < comps.size
                              Util.deserialize_big_endian_to_int(arg[offset + 32, 32]).to_i
                            else
                              arg.size
                            end
              if pointer > arg.size || next_offset > arg.size || next_offset < pointer
                raise DecodingError.new("Offset out of bounds")
              end
              result << self.type(c, arg[pointer, next_offset - pointer])
              offset += 32
            else
              size = c.size.not_nil! # статический компонент всегда имеет размер
              raise DecodingError.new("Offset out of bounds") if offset + size > arg.size
              result << self.type(c, arg[offset, size])
              offset += size
            end
          end
          result
        elsif type.dynamic?
          l = Util.deserialize_big_endian_to_int(arg[0, 32]).to_i
          nested_sub = type.nested_sub

          if nested_sub.dynamic?
            unless arg.size >= 32 + 32 * l
              raise DecodingError.new("Wrong data size for dynamic array")
            end
            offsets = (0...l).map do |i|
              off = Util.deserialize_big_endian_to_int(arg[32 + 32 * i, 32]).to_i
              if off < 32 * l || off > arg.size - 64
                raise DecodingError.new("Offset out of bounds")
              end
              off
            end
            elements = Array(Value).new
            offsets.each { |off| elements << self.type(nested_sub, arg[32 + off..]) }
            elements
          else
            unless arg.size >= 32 + (nested_sub.size || 32) * l
              raise DecodingError.new("Wrong data size for dynamic array")
            end
            elements = Array(Value).new
            (0...l).each do |i|
              elements << self.type(nested_sub, arg[32 + (nested_sub.size || 32) * i, nested_sub.size || 32])
            end
            elements
          end
        elsif !type.dimensions.empty?
          l = type.dimensions.first
          nested_sub = type.nested_sub

          if nested_sub.dynamic?
            unless arg.size >= 32 * l
              raise DecodingError.new("Wrong data size for static array")
            end
            offsets = (0...l).map do |i|
              off = Util.deserialize_big_endian_to_int(arg[32 * i, 32]).to_i
              if off < 32 * l || off > arg.size - 32
                raise DecodingError.new("Offset out of bounds")
              end
              off
            end
            elements = Array(Value).new
            offsets.each_with_index do |off, i|
              size = (i + 1 < offsets.size ? offsets[i + 1] : arg.size) - off
              elements << self.type(nested_sub, arg[off, size])
            end
            elements
          else
            size = nested_sub.size || 32
            elements = Array(Value).new
            (0...l).each { |i| elements << self.type(nested_sub, arg[size * i, size]) }
            elements
          end
        else
          primitive_type(type, arg)
        end
      end

      def self.primitive_type(type : Type, data : Bytes) : Value
        case type.base_type
        when "address"
          addr_bytes = data[data.size - 20, 20]
          addr_hex = Util.bin_to_hex(addr_bytes)
          # 20 байт + префикс 41 → TRON base58-адрес
          Utils::Address.to_base58(Tron::Key::ADDRESS_PREFIX + addr_hex)
        when "string", "bytes"
          if type.sub_type.empty?
            size = Util.deserialize_big_endian_to_int(data[0, 32]).to_i
            raw = data[32..][0, size]
            if type.base_type == "string"
              String.new(raw)
            else
              raw
            end
          else
            data[0, type.sub_type.to_i]
          end
        when "hash"
          data[(32 - type.sub_type.to_i), type.sub_type.to_i]
        when "uint"
          Util.deserialize_big_endian_to_int(data)
        when "int"
          u = Util.deserialize_big_endian_to_int(data)
          u >= (BigInt.new(2) ** (type.sub_type.to_i - 1)) ? u - (BigInt.new(2) ** 256) : u
        when "ureal", "ufixed"
          _high, low = type.sub_type.split("x").map(&.to_i)
          Util.deserialize_big_endian_to_int(data).to_f64 / (BigInt.new(2) ** low).to_f64
        when "real", "fixed"
          high, low = type.sub_type.split("x").map(&.to_i)
          u = Util.deserialize_big_endian_to_int(data)
          i = u >= (BigInt.new(2) ** (high + low - 1)) ? u - (BigInt.new(2) ** (high + low)) : u
          i.to_f64 / (BigInt.new(2) ** low).to_f64
        when "bool"
          data[data.size - 1] == Constant::BYTE_ONE[0]
        else
          raise DecodingError.new("Unknown primitive type: #{type.base_type}")
        end
      end
    end
  end
end

require "../key"
