# Tron::Utils::Address — 1:1 к tron.rb 1.2.4 (lib/tron/utils/address.rb):
# валидация base58check-адресов T…, конвертация base58 ↔ hex.

require "digest"
require "../crypto/base58"

module Tron
  module Utils
    module Address
      # Префикс TRON-адреса в hex (41 соответствует 'T' в base58).
      ADDRESS_PREFIX = "41"

      def self.validate(address : String?) : Bool
        return false unless addr = address
        return false unless addr.size == 34 && addr.starts_with?('T')

        decoded = begin
          Crypto.base58_decode(addr)
        rescue ArgumentError
          return false
        end
        # 21 байт адреса + 4 байта checksum = 25 байт
        return false unless decoded.size == 25

        addr_part = decoded[0, 21]
        checksum = decoded[21, 4]

        expected = Digest::SHA256.digest(Digest::SHA256.digest(addr_part))[0, 4]
        checksum == expected && addr_part[0] == 65 # 0x41
      end

      def self.to_hex(address : String) : String
        return address if address.starts_with?(ADDRESS_PREFIX) && address.size == 42

        decoded = Crypto.base58_decode(address)
        raise ArgumentError.new("Invalid TRON address format: #{address}") unless decoded.size == 25

        decoded[0, 21].hexstring
      end

      def self.from_hex(hex_address : String) : String
        to_base58(hex_address)
      end

      def self.to_base58(hex_address : String) : String
        return hex_address if hex_address.starts_with?('T') && hex_address.size == 34

        hex_without_prefix = hex_address.starts_with?(ADDRESS_PREFIX) ? hex_address[2..] : hex_address
        address_bytes = Crypto.hex_to_bin(hex_without_prefix)

        unless address_bytes.size == 21
          # добавить байт префикса 0x41, если его нет (20 байт)
          address_bytes = Bytes[65] + address_bytes if address_bytes.size == 20
        end

        Crypto.base58check(address_bytes)
      end
    end
  end
end
