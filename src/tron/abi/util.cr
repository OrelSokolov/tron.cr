# Tron::Abi::Util — 1:1 к tron.rb 1.2.4 (lib/tron/abi/util.rb): утилиты
# ABI-энкодинга (паддинги, hex/binary конверсии, big-endian int).

module Tron
  module Abi
    module Util
      UINT_MAX = (BigInt.new(2) ** 256) - 1
      UINT_MIN = 0_i64
      INT_MAX  = (BigInt.new(2) ** 255) - 1
      INT_MIN  = -(BigInt.new(2) ** 255)

      # Конкатенация массива байтовых строк (аналог Array#join в Ruby).
      def self.concat(parts : Array(Bytes)) : Bytes
        total = parts.sum(0) { |p| p.size }
        result = Bytes.new(total)
        offset = 0
        parts.each do |p|
          result[offset, p.size].copy_from(p)
          offset += p.size
        end
        result
      end

      # Длина, округлённая вверх до кратной 32 байтам.
      def self.ceil32(x : Int | BigInt) : Int32
        (((x.to_big_i + 31) // 32) * 32).to_i32
      end

      # Целое, дополненное нулями до len байт (big-endian, binary).
      def self.zpad_int(x : Int | BigInt, len : Int32 = 32) : Bytes
        v = x.to_big_i
        mod = BigInt.new(2) ** (8 * len)
        v = v % mod if v >= mod || v < 0
        hex_to_bin(v.to_s(16).rjust(len * 2, '0'))
      end

      # Байты, дополненные нулями до length.
      def self.zpad(s : Bytes, length : Int32) : Bytes
        padded = Bytes.new(length)
        s.copy_to(padded)
        padded
      end

      # Hex-строка, дополненная нулями до 32 байт (64 hex-символов), → binary.
      def self.zpad_hex(s : String) : Bytes
        s = s[2..] if s.starts_with?("0x") || s.starts_with?("0X")
        hex_to_bin(s.rjust(64, '0'))
      end

      def self.prefixed?(s : String) : Bool
        s.starts_with?("0x") || s.starts_with?("0X")
      end

      def self.hex?(s : String) : Bool
        s = s[2..] if s.starts_with?("0x") || s.starts_with?("0X")
        s.matches?(/\A[0-9a-fA-F]*\z/)
      end

      # Hex → binary. Как pack('H*') в Ruby: нечётный хвост отбрасывается.
      def self.hex_to_bin(s : String) : Bytes
        s = s[2..] if s.starts_with?("0x") || s.starts_with?("0X")
        s = s[0...(s.size & ~1)] if s.size.odd?
        Tron::Crypto.hex_to_bin(s)
      end

      def self.bin_to_hex(b : Bytes) : String
        b.hexstring
      end

      # Big-endian integer из binary.
      def self.deserialize_big_endian_to_int(data : Bytes) : BigInt
        return BigInt.new(0) if data.empty?
        data.hexstring.to_big_i(16)
      end

      # Семантика Ruby String#to_i(0): автоопределение базы по префиксу
      # (0x/0b/0o, ведущий 0 — восьмеричная), невалидный старт → 0,
      # хвостовой мусор игнорируется.
      def self.to_i_base0(s : String) : BigInt
        str = s.lstrip
        i = 0
        sign = BigInt.new(1)

        if ch = str[i]?
          if ch == '-'
            sign = BigInt.new(-1)
            i += 1
          elsif ch == '+'
            i += 1
          end
        end

        base = 10
        if str[i]? == '0'
          nxt = str[i + 1]?
          if nxt && nxt.in?('x', 'X') && str[i + 2]?.try { |c| c.hex? }
            base = 16
            i += 2
          elsif nxt && nxt.in?('b', 'B') && str[i + 2]?.try { |c| c.in?('0', '1') }
            base = 2
            i += 2
          elsif nxt && nxt.in?('o', 'O') && str[i + 2]?.try { |c| c.in?('0'..'7') }
            base = 8
            i += 2
          elsif nxt && nxt.ascii_number?
            base = 8
            i += 1
          else
            # "0" или "0x" без цифр: парсится как 0
            return BigInt.new(0)
          end
        end

        value = BigInt.new(0)
        digits = 0
        while ch = str[i]?
          d = digit_value(ch, base)
          break if d.nil? || d >= base
          value = value * base + d
          digits += 1
          i += 1
        end

        return BigInt.new(0) if digits.zero?
        sign * value
      end

      private def self.digit_value(ch : Char, base : Int32) : Int32?
        case ch
        when .ascii_number? then ch - '0'
        when .ascii_letter?
          v = ch.downcase - 'a' + 10
          v < 36 ? v : nil
        else nil
        end
      end
    end
  end
end

require "../crypto/base58"
