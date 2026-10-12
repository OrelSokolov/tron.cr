# Base58 / Base58Check (bitcoin-алфавит, как в base58-alphabets у tron.rb:
# checksum = sha256(sha256(payload))[0,4]).

require "digest"

module Tron
  module Crypto
    ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    def self.base58_encode(data : Bytes) : String
      return "" if data.empty?
      # ведущие нулевые байты → '1' (как в bitcoin base58)
      zeros = 0
      while zeros < data.size && data[zeros] == 0
        zeros += 1
      end

      # big-endian число в базе 58
      digits = Array(UInt8).new
      data.each do |byte|
        carry = byte.to_i32
        digits.each_with_index do |d, i|
          carry += d.to_i32 << 8
          digits[i] = (carry % 58).to_u8
          carry //= 58
        end
        while carry > 0
          digits << (carry % 58).to_u8
          carry //= 58
        end
      end

      result = ("1" * zeros) + digits.reverse.map { |d| ALPHABET[d] }.join
      result
    end

    def self.base58_decode(data : String) : Bytes
      # ведущие '1' — это нулевые байты (считать только ведущие)
      zeros = 0
      while zeros < data.size && data[zeros] == '1'
        zeros += 1
      end

      bytes = Array(UInt8).new
      data.each_char do |ch|
        value = ALPHABET.index(ch)
        raise ArgumentError.new("invalid base58 character: #{ch}") unless value
        carry = value
        bytes.each_with_index do |b, i|
          carry += b.to_i32 * 58
          bytes[i] = (carry & 0xFF).to_u8
          carry >>= 8
        end
        while carry > 0
          bytes << (carry & 0xFF).to_u8
          carry >>= 8
        end
      end

      # 21-байтный адрес: ведущие нули + big-endian число
      reversed = bytes.reverse
      result = Bytes.new(zeros + reversed.size)
      reversed.each_with_index { |b, i| result[zeros + i] = b }
      result
    end

    def self.base58check(payload : Bytes) : String
      checksum = Digest::SHA256.digest(Digest::SHA256.digest(payload))[0, 4]
      base58_encode(payload + checksum)
    end
  end
end
