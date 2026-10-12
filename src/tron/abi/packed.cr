# Tron::Abi::Packed::Encoder — 1:1 к tron.rb 1.2.4 (lib/tron/abi/packed/encoder.rb):
# нестандартное packed-кодирование (без паддинга до 32 байт).

require "./type"
require "./util"
require "./constant"
require "../utils/address"

module Tron
  module Abi
    module Packed
      module Encoder
        def self.type(type : String, arg : Value) : Bytes
          case type
          when /^uint(\d+)$/
            uint(arg, $1.not_nil!.to_i // 8)
          when /^int(\d+)$/
            int(arg, $1.not_nil!.to_i // 8)
          when "bool"
            bool(arg)
          when /^ureal(\d+)x(\d+)$/, /^ufixed(\d+)x(\d+)$/
            ufixed(arg, $1.not_nil!.to_i // 8, $2.not_nil!.to_i)
          when /^real(\d+)x(\d+)$/, /^fixed(\d+)x(\d+)$/
            fixed(arg, $1.not_nil!.to_i // 8, $2.not_nil!.to_i)
          when "string"
            string(arg)
          when /^bytes(\d+)$/
            bytes(arg, $1.not_nil!.to_i)
          when "bytes"
            string(arg)
          when /^tuple\((.+)\)$/
            tuple($1.not_nil!.split(","), arg)
          when /^hash(\d+)$/
            hash(arg, $1.not_nil!.to_i // 8)
          when "address"
            address(arg)
          when /^(.+)\[\]$/
            array($1.not_nil!, arg)
          when /^(.+)\[(\d+)\]$/
            fixed_array($1.not_nil!, arg, $2.not_nil!.to_i)
          else
            raise EncodingError.new("Unhandled type: #{type}")
          end
        end

        def self.uint(value : Value, byte_size : Int32) : Bytes
          i = packed_int(value)
          if i > Constant::UINT_MAX || i < Constant::UINT_MIN
            raise ValueOutOfBounds.new("Number out of range: #{value}")
          end
          Util.zpad_int(i, byte_size)
        end

        def self.int(value : Value, byte_size : Int32) : Bytes
          i = packed_int(value)
          if i > Constant::INT_MAX || i < Constant::INT_MIN
            raise ValueOutOfBounds.new("Number out of range: #{value}")
          end
          real_size = byte_size * 8
          Util.zpad_int(i % (BigInt.new(2) ** real_size), byte_size)
        end

        def self.bool(value : Value) : Bytes
          raise EncodingError.new("Argument is not bool: #{value}") unless value.is_a?(Bool)
          value.as(Bool) ? Bytes[1] : Bytes[0]
        end

        def self.ufixed(value : Value, byte_size : Int32, decimals : Int32) : Bytes
          f = packed_float(value)
          raise ValueOutOfBounds.new(value.to_s) unless f >= 0 && f < (2 ** decimals).to_f64
          # как в tron.rb: масштабирование на 10**decimals
          uint(((f * (10 ** decimals)).to_i64).to_big_i, byte_size)
        end

        def self.fixed(value : Value, byte_size : Int32, decimals : Int32) : Bytes
          f = packed_float(value)
          unless f >= -((2 ** (decimals - 1)).to_f64) && f < (2 ** (decimals - 1)).to_f64
            raise ValueOutOfBounds.new(value.to_s)
          end
          int(((f * (10 ** decimals)).to_i64).to_big_i, byte_size)
        end

        def self.bytes(value : Value, length : Int32) : Bytes
          raise EncodingError.new("Expecting String: #{value}") unless value.is_a?(String)
          data = handle_hex_string(value.as(String), length)
          unless data.size == length
            raise ArgumentError.new("Value must be a string of length #{length}")
          end
          data
        end

        def self.string(value : Value) : Bytes
          raise ArgumentError.new("Value must be a string") unless value.is_a?(String)
          value.as(String).to_slice
        end

        def self.tuple(types : Array(String), values : Value) : Bytes
          Tron::Abi.solidity_packed(types, values.as(Array(Value)))
        end

        def self.hash(value : Value, byte_size : Int32) : Bytes
          unless byte_size > 0 && byte_size <= 32
            raise EncodingError.new("Argument too long: #{value}")
          end
          raise EncodingError.new("Expecting String: #{value}") unless value.is_a?(String)
          handle_hex_string(value.as(String), byte_size)
        end

        def self.address(value : Value) : Bytes
          case value
          when String
            s = value.as(String)
            if s.starts_with?('T') && s.size == 34
              hex_addr = Utils::Address.to_hex(s)
              Util.hex_to_bin(hex_addr[2..]) # 20 сырых байт без префикса 41
            elsif s.size == 40
              Util.hex_to_bin(s)
            elsif s.size == 42 && s[0, 2] == "0x"
              Util.hex_to_bin(s[2..])
            else
              raise EncodingError.new("Could not parse address: #{value}")
            end
          when Int, BigInt
            Util.zpad_int(value, 20)
          when Bytes
            value.as(Bytes)
          else
            raise EncodingError.new("Could not parse address: #{value}")
          end
        end

        def self.array(type : String, values : Value) : Bytes
          Tron::Abi::Util.concat(values.as(Array(Value)).map { |value| self.type(type, value) })
        end

        def self.fixed_array(type : String, values : Value, size : Int32) : Bytes
          arr = values.as(Array(Value))
          raise ArgumentError.new("Array size does not match") unless arr.size == size
          Tron::Abi::Util.concat(arr.map { |value| self.type(type, value) })
        end

        def self.handle_hex_string(val : String, len : Int32) : Bytes
          if Util.prefixed?(val) || (len == val.size // 2 && Util.hex?(val))
            Util.hex_to_bin(val)
          else
            val.to_slice
          end
        end

        private def self.packed_int(value : Value) : BigInt
          case value
          when Int32, Int64 then value.to_big_i
          when BigInt       then value
          when Float64      then value.to_i64.to_big_i
          else raise ArgumentError.new("Don't know how to handle this input.")
          end
        end

        private def self.packed_float(value : Value) : Float64
          case value
          when Int32, Int64 then value.to_f64
          when BigInt       then value.to_f64
          when Float64      then value
          else raise ArgumentError.new("Don't know how to handle this input.")
          end
        end
      end
    end
  end
end
