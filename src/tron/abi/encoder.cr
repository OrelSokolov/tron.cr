# Tron::Abi::Encoder — 1:1 к tron.rb 1.2.4 (lib/tron/abi/encoder.rb).

require "./util"
require "./constant"
require "./type"
require "../utils/address"

module Tron
  module Abi
    module Encoder
      # Кодирует значение (статическое или динамическое) → 32-байтовые слова.
      def self.type(type : Type, arg : Value) : Bytes
        if type.base_type.in?("string", "bytes") && type.sub_type.empty? && type.dimensions.empty?
          raise EncodingError.new("Argument must be a String") unless arg.is_a?(String)
          data = handle_hex_string(arg, type)

          size = self.type(Type.size_type, data.size)
          padding = Bytes.new(Util.ceil32(data.size) - data.size)
          size + data + padding
        elsif type.base_type == "tuple" && type.dimensions.size == 1 && type.dimensions[0] != 0
          arr = case arg
                when Array(Value) then arg
                else raise EncodingError.new("Expecting Array: #{arg}")
                end
          result = struct_offsets(type.nested_sub, arr)
          arr.each { |x| result += self.type(type.nested_sub, x) }
          result
        elsif type.dynamic? && !type.dimensions.empty? && arg.is_a?(Array(Value))
          # массивы динамического размера
          arr = arg.as(Array(Value))
          head = self.type(Type.size_type, arr.size)
          nested_sub = type.nested_sub

          if nested_sub.dynamic?
            tails = arr.map { |a| self.type(nested_sub, a) }
            offset = arr.size * 32
            tails.each do |t|
              head += self.type(Type.size_type, offset)
              offset += t.size
            end
            head + Util.concat(tails)
          else
            arr.each { |a| head += self.type(nested_sub, a) }
            head
          end
        else
          if type.dimensions.empty?
            primitive_type(type, arg)
          else
            static_arr = case arg
                         when Array(Value) then arg
                         else raise EncodingError.new("Expecting Array: #{arg}")
                         end
            Util.concat(static_arr.map { |x| self.type(type.nested_sub, x) })
          end
        end
      end

      def self.primitive_type(type : Type, arg : Value) : Bytes
        case type.base_type
        when "uint"           then uint(arg, type)
        when "int"            then int(arg, type)
        when "bool"           then bool(arg)
        when "ureal", "ufixed" then ufixed(arg, type)
        when "real", "fixed"  then fixed(arg, type)
        when "string", "bytes" then bytes(arg, type)
        when "tuple"          then tuple(arg, type)
        when "hash"           then hash(arg, type)
        when "address"        then address(arg)
        else raise EncodingError.new("Unhandled type: #{type.base_type} #{type.sub_type}")
        end
      end

      def self.uint(arg : Value, type : Type) : Bytes
        arg = coerce_number(arg)
        unless arg.is_a?(Int) || arg.is_a?(BigInt) || arg.is_a?(Float64)
          raise ArgumentError.new("Don't know how to handle this input.")
        end
        i = numeric_to_bigint(arg)
        if i > Util::UINT_MAX || i < Util::UINT_MIN
          raise ValueOutOfBounds.new("Number out of range: #{arg}")
        end
        real_size = type.sub_type.to_i
        raise ValueOutOfBounds.new(arg.to_s) unless i >= 0 && i < (BigInt.new(2) ** real_size)
        Util.zpad_int(i)
      end

      def self.int(arg : Value, type : Type) : Bytes
        arg = coerce_number(arg)
        unless arg.is_a?(Int) || arg.is_a?(BigInt) || arg.is_a?(Float64)
          raise ArgumentError.new("Don't know how to handle this input.")
        end
        i = numeric_to_bigint(arg)
        if i > Util::INT_MAX || i < Util::INT_MIN
          raise ValueOutOfBounds.new("Number out of range: #{arg}")
        end
        real_size = type.sub_type.to_i
        unless i >= -(BigInt.new(2) ** (real_size - 1)) && i < (BigInt.new(2) ** (real_size - 1))
          raise ValueOutOfBounds.new(arg.to_s)
        end
        Util.zpad_int(i % (BigInt.new(2) ** 256))
      end

      def self.bool(arg : Value) : Bytes
        raise EncodingError.new("Argument is not bool: #{arg}") unless arg.is_a?(Bool)
        Util.zpad_int(arg.as(Bool) ? 1 : 0)
      end

      def self.ufixed(arg : Value, type : Type) : Bytes
        arg = coerce_number(arg)
        unless arg.is_a?(Int) || arg.is_a?(BigInt) || arg.is_a?(Float64)
          raise ArgumentError.new("Don't know how to handle this input.")
        end
        high, low = type.sub_type.split("x").map(&.to_i)
        f = numeric_to_f64(arg)
        raise ValueOutOfBounds.new(arg.to_s) unless f >= 0 && f < 2.0_f64 ** high
        Util.zpad_int((f * (2.0_f64 ** low)).to_i64)
      end

      def self.fixed(arg : Value, type : Type) : Bytes
        arg = coerce_number(arg)
        unless arg.is_a?(Int) || arg.is_a?(BigInt) || arg.is_a?(Float64)
          raise ArgumentError.new("Don't know how to handle this input.")
        end
        high, low = type.sub_type.split("x").map(&.to_i)
        f = numeric_to_f64(arg)
        unless f >= -(2.0_f64 ** (high - 1)) && f < 2.0_f64 ** (high - 1)
          raise ValueOutOfBounds.new(arg.to_s)
        end
        i = (f * (2.0_f64 ** low)).to_i64
        Util.zpad_int(BigInt.new(i) % (BigInt.new(2) ** (high + low)))
      end

      def self.bytes(arg : Value, type : Type) : Bytes
        raise EncodingError.new("Expecting String: #{arg}") unless arg.is_a?(String)
        data = handle_hex_string(arg.as(String), type)

        if type.sub_type.empty?
          size = Util.zpad_int(data.size)
          padding = Bytes.new(Util.ceil32(data.size) - data.size)
          size + data + padding
        else
          raise ValueOutOfBounds.new(arg.to_s) unless data.size <= type.sub_type.to_i
          padding = Bytes.new(32 - data.size)
          data + padding
        end
      end

      def self.tuple(arg : Value, type : Type) : Bytes
        unless arg.is_a?(Hash(String, Value)) || arg.is_a?(Array(Value))
          raise EncodingError.new("Expecting Hash or Array: #{arg}")
        end
        comps = type.components || raise EncodingError.new("tuple without components")
        arg_size = arg.is_a?(Hash(String, Value)) ? arg.as(Hash(String, Value)).size : arg.as(Array(Value)).size
        unless arg_size == comps.size
          raise EncodingError.new("Expecting #{comps.size} elements: #{arg}")
        end

        static_size = 0
        comps.each_with_index do |_, i|
          if comps[i].dynamic?
            static_size += 32
          else
            static_size += Util.ceil32(comps[i].size || 0)
          end
        end

        dynamic_offset = static_size
        offsets_and_static = Bytes.empty
        dynamic_values = Bytes.empty

        comps.each_with_index do |component, i|
          if component.dynamic?
            offsets_and_static += self.type(Type.size_type, dynamic_offset)
            value = tuple_arg_fetch(arg, i, component.name)
            dynamic_value = self.type(component, value)
            dynamic_values += dynamic_value
            dynamic_offset += dynamic_value.size
          else
            value = tuple_arg_fetch(arg, i, component.name)
            offsets_and_static += self.type(component, value)
          end
        end

        offsets_and_static + dynamic_values
      end

      def self.coerce_number(arg : Value) : Value
        case arg
        when String
          if arg =~ /\A-?(0x)?[0-9a-fA-F]+\z/
            Util.to_i_base0(arg)
          elsif arg =~ /\A-?\d+(\.\d+)?\z/
            arg.to_f64
          else
            arg
          end
        else arg
        end
      end

      def self.struct_offsets(type : Type, arg : Array(Value)) : Bytes
        result = Bytes.empty
        tails_encoding = arg.map { |a| self.type(type, a) }
        offset = arg.size
        arg.size.times do |i|
          if i == 0
            offset *= 32
          else
            offset += tails_encoding[i - 1].size
          end
          result += self.type(Type.size_type, offset)
        end
        result
      end

      def self.hash(arg : Value, type : Type) : Bytes
        size = type.sub_type.to_i
        unless size > 0 && size <= 32
          raise EncodingError.new("Argument too long: #{arg}")
        end
        if arg.is_a?(Int) || arg.is_a?(BigInt)
          Util.zpad_int(arg)
        elsif arg.is_a?(String)
          s = arg.as(String)
          if s.size == size * 2
            Util.zpad_hex(s)
          elsif s.size == size
            Util.zpad(s.to_slice, 32)
          else
            raise EncodingError.new("Could not parse hash: #{arg}")
          end
        else
          raise EncodingError.new("Could not parse hash: #{arg}")
        end
      end

      def self.address(arg : Value) : Bytes
        case arg
        when String
          s = arg.as(String)
          if s.starts_with?('T') && s.size == 34
            hex_addr = Utils::Address.to_hex(s)
            Util.zpad_hex(hex_addr[2..]) # без префикса 41, паддится до 32 байт
          elsif s.size == 40
            Util.zpad_hex(s)
          elsif s.size == 42 && s[0, 2] == "0x"
            Util.zpad_hex(s[2..])
          else
            raise EncodingError.new("Could not parse address: #{arg}")
          end
        when Int, BigInt
          Util.zpad_int(arg)
        when Bytes
          b = arg.as(Bytes)
          if b.size == 20
            Util.zpad(b, 32)
          else
            raise EncodingError.new("Could not parse address: #{arg}")
          end
        else
          raise EncodingError.new("Could not parse address: #{arg}")
        end
      end

      # Различение hex- и бинарной строки: 0x-префикс либо точное совпадение
      # длины с ожидаемой бинарной (sub_type) — считаем hex.
      def self.handle_hex_string(arg : String, type : Type) : Bytes
        if Util.prefixed?(arg) || (arg.size == (type.sub_type.to_i? || 0) * 2 && Util.hex?(arg))
          Util.hex_to_bin(arg)
        else
          arg.to_slice
        end
      end

      private def self.tuple_arg_fetch(arg : Value, index : Int32, name : String?) : Value
        if arg.is_a?(Array(Value))
          arg.as(Array(Value))[index]
        else
          hash = arg.as(Hash(String, Value))
          key = name
          if key.nil? || !hash.has_key?(key)
            raise KeyError.new("key not found: #{key.inspect}")
          end
          hash[key.not_nil!]
        end
      end

      private def self.numeric_to_bigint(v : Value) : BigInt
        case v
        when Int32, Int64 then v.to_big_i
        when BigInt       then v
        when Float64      then v.to_i64.to_big_i # Ruby .to_i усекает
        else raise ArgumentError.new("Don't know how to handle this input.")
        end
      end

      private def self.numeric_to_f64(v : Value) : Float64
        case v
        when Int32, Int64 then v.to_f64
        when BigInt       then v.to_f64
        when Float64      then v
        else raise ArgumentError.new("Don't know how to handle this input.")
        end
      end
    end
  end
end
