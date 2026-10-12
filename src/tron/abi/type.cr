# Tron::Abi::Type — 1:1 к tron.rb 1.2.4 (lib/tron/abi/type.rb): парсер
# Solidity-типов (вкл. tuple и массивы).

module Tron
  module Abi
    class Type
      class ParseError < Exception
      end

      # Спецификация компонента (из ABI-JSON или инлайн-tuple).
      struct ComponentSpec
        getter type : String
        getter components : Array(ComponentSpec)?
        getter name : String?

        def initialize(@type, @components, @name)
        end

        def self.from_json(any : JSON::Any) : ComponentSpec
          comps = any["components"]?.try &.as_a.map { |c| ComponentSpec.from_json(c) }
          ComponentSpec.new(any["type"].as_s, comps, any["name"]?.try &.as_s)
        end
      end

      getter base_type : String
      getter sub_type : String
      getter dimensions : Array(Int32)
      getter components : Array(Type)?
      getter name : String?

      # Создавать через Type.parse, не напрямую (как в tron.rb).
      def initialize(@base_type : String, @sub_type : String, @dimensions : Array(Int32),
                     @components : Array(Type)?, @name : String?)
      end

      def self.parse(type : String, components : Array(ComponentSpec)? = nil,
                     component_name : String? = nil) : Type
        base_type = ""
        sub_type = ""
        dimension = ""
        inline_components : Array(ComponentSpec)? = components

        if type.starts_with?("tuple(") || type.starts_with?("(")
          tuple_str = type.starts_with?("tuple(") ? type : "tuple#{type}"
          inner, rest = extract_tuple(tuple_str)
          inner_types = split_tuple_types(inner)
          inner_types.each { |t| Type.parse(t) } # валидация вложенных типов
          base_type = "tuple"
          sub_type = ""
          dimension = rest
          inline_components ||= inner_types.map { |t| ComponentSpec.new(t, nil, nil) }
        else
          match = /\A([a-z]+)([0-9]*x?[0-9]*)((?:\[\d+\]|\[\])*)\z/.match(type)
          raise ParseError.new("Invalid type format") unless match
          base_type = match[1].not_nil!
          sub_type = match[2].not_nil!
          dimension = match[3].not_nil!
          sub_type = "256" if base_type.in?("uint", "int") && sub_type.empty?
        end

        dims_scanned = dimension.scan(/\[\d+\]|\[\]/).map(&.[0])
        unless dims_scanned.join == dimension
          raise ParseError.new("Unknown characters found in array declaration")
        end

        validate_base_type(base_type, sub_type)

        dims = dims_scanned.map { |x| x == "[]" ? 0 : x[1...-1].to_i }

        parsed_components = nil
        if (comps = inline_components) && !comps.empty?
          parsed_components = comps.map do |component|
            Type.parse(component.type, component.components, component.name)
          end
        end

        Type.new(base_type, sub_type, dims, parsed_components, component_name)
      end

      @@size_type : Type? = nil

      def self.size_type : Type
        @@size_type ||= Type.new("uint", "256", [] of Int32, nil, nil)
      end

      def ==(other : Type) : Bool
        base_type == other.base_type &&
          sub_type == other.sub_type &&
          dimensions == other.dimensions
      end

      @size : Int32? = nil
      @nested_sub : Type? = nil

      def size : Int32?
        s = @size
        return s unless s.nil?
        s = compute_size
        @size ||= s
        s
      end

      def dynamic? : Bool
        size.nil?
      end

      def nested_sub : Type
        @nested_sub ||= Type.new(base_type, sub_type, dimensions[0...-1], components, name)
      end

      def to_s : String
        if base_type == "tuple"
          comps = components || raise ParseError.new("tuple without components")
          "(" + comps.map(&.to_s).join(",") + ")" +
            (dimensions.size > 0 ? dimensions.map { |x| "[#{x == 0 ? "" : x}]" }.join : "")
        elsif dimensions.empty?
          if base_type.in?("string", "bytes") && sub_type.empty?
            base_type
          else
            "#{base_type}#{sub_type}"
          end
        else
          "#{base_type}#{sub_type}#{dimensions.map { |x| "[#{x == 0 ? "" : x}]" }.join}"
        end
      end

      private def compute_size : Int32?
        if dimensions.empty?
          if !(base_type.in?("string", "bytes", "tuple") && sub_type.empty?)
            32
          elsif base_type == "tuple" && components && components.not_nil!.none?(&.dynamic?)
            components.not_nil!.sum { |c| c.size || 0 }
          end
        elsif dimensions.last != 0 && !nested_sub.dynamic?
          nested_sub.size.try { |s| dimensions.last * s }
        end
      end

      def self.validate_base_type(base_type : String, sub_type : String) : Nil
        case base_type
        when "string"
          raise ParseError.new("String type must have no suffix or numerical suffix") unless sub_type.empty?
        when "bytes"
          unless sub_type.empty? || (sub_type.to_i <= 32 && sub_type.to_i > 0)
            raise ParseError.new("Maximum 32 bytes for fixed-length string or bytes")
          end
        when "tuple"
          raise ParseError.new("Tuple type must have no suffix or numerical suffix") unless sub_type.empty?
        when "uint", "int"
          raise ParseError.new("Integer type must have numerical suffix") unless sub_type =~ /\A[0-9]+\z/
          size = sub_type.to_i
          raise ParseError.new("Integer size out of bounds") unless size >= 8 && size <= 256
          raise ParseError.new("Integer size must be multiple of 8") unless size % 8 == 0
        when "ureal", "real", "fixed", "ufixed"
          unless sub_type =~ /\A[0-9]+x[0-9]+\z/
            raise ParseError.new("Real type must have suffix of form <size>x<decimals>, e.g. 128x128")
          end
          size, decimals = sub_type.split("x").map(&.to_i)
          total = size + decimals
          raise ParseError.new("Real size out of bounds (max 32 bytes)") unless total >= 8 && total <= 256
          raise ParseError.new("Real size must be multiples of 8") unless size % 8 == 0
        when "hash"
          raise ParseError.new("Hash type must have numerical suffix") unless sub_type =~ /\A[0-9]+\z/
        when "address"
          raise ParseError.new("Address cannot have suffix") unless sub_type.empty?
        when "bool"
          raise ParseError.new("Bool cannot have suffix") unless sub_type.empty?
        else
          raise ParseError.new("Unknown base type")
        end
      end

      private def self.extract_tuple(type : String) : {String, String}
        idx = 6 # пропустить "tuple("
        depth = 1
        while idx < type.size && depth > 0
          case type[idx]
          when '(' then depth += 1
          when ')' then depth -= 1
          end
          idx += 1
        end
        raise ParseError.new("Invalid tuple format") unless depth.zero?
        inner = type[6...(idx - 1)]
        rest = type[idx..]? || ""
        {inner, rest}
      end

      private def self.split_tuple_types(str : String) : Array(String)
        types = [] of String
        depth = 0
        current = ""
        str.each_char do |ch|
          case ch
          when '(' then depth += 1; current += ch
          when ')' then depth -= 1; current += ch
          when ','
            if depth.zero?
              types << current
              current = ""
            else
              current += ch
            end
          else current += ch
          end
        end
        types << current unless current.empty?
        types
      end
    end
  end
end

require "json"
