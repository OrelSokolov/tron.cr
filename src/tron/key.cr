# Tron::Key — 1:1 к tron.rb 1.2.4 (lib/tron/key.rb): генерация/загрузка
# ключа, деривация адреса (keccak256 + 0x41 + base58check), подписи.

require "./crypto/keccak"
require "./crypto/base58"
require "./crypto/secp256k1"

module Tron
  class Key
    ADDRESS_PREFIX = "41"

    getter private_key : Bytes  # 32 байта
    getter public_key : Bytes   # несжатый, 65 байт (0x04 || X || Y)

    def initialize(priv : String? = nil)
      @context = Crypto::Secp256k1.new

      if priv
        data = Crypto.hex_to_bin(priv)
        raise ArgumentError.new("Private key must be 32 bytes") unless data.size == 32
        raise ArgumentError.new("Invalid private key") unless @context.seckey_valid?(data)
        @private_key = data
      else
        @private_key = Random::Secure.random_bytes(32)
        until @context.seckey_valid?(@private_key)
          @private_key = Random::Secure.random_bytes(32)
        end
      end

      @public_key = @context.pubkey_create(@private_key, compressed: false)
    end

    def private_hex : String
      @private_key.hexstring
    end

    def private_bytes : Bytes
      @private_key
    end

    def public_hex : String
      @public_key.hexstring
    end

    def public_hex_compressed : String
      public_bytes_compressed.hexstring
    end

    def public_bytes : Bytes
      @public_key
    end

    def public_bytes_compressed : Bytes
      @context.pubkey_create(@private_key, compressed: true)
    end

    # TRON-адрес: keccak256(pub[1..])[last 20] + 0x41 → base58check.
    def address : String
      hash = Crypto.keccak256(@public_key[1, 64])
      address_bytes = hash[hash.size - 20, 20]
      prefixed = Bytes.new(21)
      prefixed[0] = 0x41
      20.times { |i| prefixed[i + 1] = address_bytes[i] }
      Crypto.base58check(prefixed)
    end

    # Подпись 32-байтового blob → hex (65 байт: 64 подпись + recid).
    def sign(blob : Bytes) : String
      compact, recid = @context.sign_recoverable(blob, @private_key)
      (compact + Bytes[recid.to_u8!]).hexstring
    end

    # personal_sign: Ethereum-style префикс + keccak256 + sign.
    def personal_sign(message : String) : String
      prefixed = Signature.prefix_message(message)
      sign(Crypto.keccak256(prefixed))
    end

    # TIP-191: v = 27 + recid.
    def sign_typed_data(hash : Bytes) : String
      prefix = "\x19Tron Signed Message:\n32"
      prefixed_hash = Crypto.keccak256(prefix.to_slice + hash)
      compact, recid = @context.sign_recoverable(prefixed_hash, @private_key)
      (compact + Bytes[(27 + recid).to_u8!]).hexstring
    end

    # Расширение порта (в tron.rb 1.2.4 публичного verify нет).
    def verify(blob : Bytes, signature_hex : String, public_key : Bytes? = nil) : Bool
      signature = Crypto.hex_to_bin(signature_hex)
      @context.verify(blob, signature, public_key || @public_key)
    end
  end

  module Signature
    # "\x19Tron Signed Message:\n" + длина + сообщение (TIP-191 personal).
    def self.prefix_message(message : String) : Bytes
      prefix = "\x19Tron Signed Message:\n#{message.bytesize}"
      prefix.to_slice + message.to_slice
    end
  end

  module Crypto
    def self.hex_to_bin(hex : String) : Bytes
      raise ArgumentError.new("bad hex string: #{hex}") unless hex.size.even?
      bytes = Bytes.new(hex.size // 2)
      (hex.size // 2).times do |i|
        byte = hex[i * 2, 2].to_u8?(16)
        raise ArgumentError.new("bad hex string: #{hex}") unless byte
        bytes[i] = byte
      end
      bytes
    end
  end
end
