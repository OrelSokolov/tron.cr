# Биндинг libsecp256k1 (та же C-библиотека, что за rbsecp256k1 у tron.rb —
# подписи детерминированы RFC 6979 и совпадают байт-в-байт).

@[Link("secp256k1", pkg_config: "libsecp256k1")]
lib LibSecp256k1
  # Флаги из secp256k1.h (значения сверены с заголовком):
  # TYPE_CONTEXT=1<<0, BIT_CONTEXT_SIGN=1<<9, TYPE_COMPRESSION=1<<1,
  # BIT_COMPRESSION=1<<8
  CONTEXT_SIGN = 0x201
  EC_COMPRESSED = 0x102
  EC_UNCOMPRESSED = 0x2

  type Context = Void*
  type Pubkey = Void*
  type EcdsaSignature = Void*
  type RecoverableSignature = Void*

  fun secp256k1_context_create(flags : UInt32) : Context
  fun secp256k1_context_destroy(ctx : Context)

  fun secp256k1_ec_seckey_verify(ctx : Context, seckey : UInt8*) : Int32
  fun secp256k1_ec_pubkey_create(ctx : Context, pubkey : UInt8*, seckey : UInt8*) : Int32
  fun secp256k1_ec_pubkey_serialize(ctx : Context, output : UInt8*, outputlen : UInt64*, pubkey : UInt8*, flags : UInt32) : Int32

  fun secp256k1_ecdsa_sign_recoverable(ctx : Context, sig : UInt8*, msg32 : UInt8*, seckey : UInt8*, noncefp : Void*, ndata : Void*) : Int32
  fun secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx : Context, output64 : UInt8*, recid : Int32*, sig : UInt8*) : Int32
  fun secp256k1_ecdsa_recoverable_signature_parse_compact(ctx : Context, sig : UInt8*, input64 : UInt8*, recid : Int32) : Int32
  fun secp256k1_ecdsa_recover(ctx : Context, pubkey : UInt8*, sig : UInt8*, msg32 : UInt8*) : Int32

  fun secp256k1_ecdsa_signature_parse_compact(ctx : Context, sig : UInt8*, input64 : UInt8*) : Int32
  fun secp256k1_ecdsa_verify(ctx : Context, sig : UInt8*, msg32 : UInt8*, pubkey : UInt8*) : Int32

  fun secp256k1_ec_pubkey_parse(ctx : Context, pubkey : UInt8*, input : UInt8*, inputlen : UInt64) : Int32

  # flags для ec_pubkey_serialize
  SECP256K1_EC_COMPRESSED = 0x1 | 0x2
  SECP256K1_EC_UNCOMPRESSED = 0x2
end

module Tron
  module Crypto
    class Secp256k1Error < Exception
    end

    # Обёртка контекста libsecp256k1.
    class Secp256k1
      def initialize
        flags = LibSecp256k1::CONTEXT_SIGN
        @ctx = LibSecp256k1.secp256k1_context_create(flags)
        raise Secp256k1Error.new("context_create failed") if @ctx.null?
      end

      def finalize
        LibSecp256k1.secp256k1_context_destroy(@ctx) unless @ctx.null?
      end

      def seckey_valid?(seckey : Bytes) : Bool
        raise Secp256k1Error.new("seckey must be 32 bytes") unless seckey.size == 32
        LibSecp256k1.secp256k1_ec_seckey_verify(@ctx, seckey) == 1
      end

      # Публичный ключ (serialized, uncompressed 65 байт или compressed 33).
      def pubkey_create(seckey : Bytes, compressed : Bool = false) : Bytes
        internal = Bytes.new(64)
        if LibSecp256k1.secp256k1_ec_pubkey_create(@ctx, internal, seckey) != 1
          raise Secp256k1Error.new("ec_pubkey_create failed")
        end
        serialize_pubkey(internal, compressed)
      end

      # Восстановление публичного ключа из подписи (recid 0..3).
      def recover(msg32 : Bytes, signature65 : Bytes) : Bytes
        recid = signature65[64]
        compact = signature65[0, 64]
        internal_sig = Bytes.new(65)
        if LibSecp256k1.secp256k1_ecdsa_recoverable_signature_parse_compact(@ctx, internal_sig, compact, recid) != 1
          raise Secp256k1Error.new("signature_parse_compact failed")
        end
        internal_pub = Bytes.new(64)
        if LibSecp256k1.secp256k1_ecdsa_recover(@ctx, internal_pub, internal_sig, msg32) != 1
          raise Secp256k1Error.new("ecdsa_recover failed")
        end
        serialize_pubkey(internal_pub, false)
      end

      # Детерминированная подпись (RFC 6979): {compact(64), recid}.
      def sign_recoverable(msg32 : Bytes, seckey : Bytes) : {Bytes, Int32}
        raise Secp256k1Error.new("msg32 must be 32 bytes") unless msg32.size == 32
        internal_sig = Bytes.new(65)
        if LibSecp256k1.secp256k1_ecdsa_sign_recoverable(@ctx, internal_sig, msg32, seckey, nil, nil) != 1
          raise Secp256k1Error.new("ecdsa_sign_recoverable failed")
        end
        compact = Bytes.new(64)
        recid = 0
        if LibSecp256k1.secp256k1_ecdsa_recoverable_signature_serialize_compact(@ctx, compact, pointerof(recid), internal_sig) != 1
          raise Secp256k1Error.new("signature_serialize_compact failed")
        end
        {compact, recid}
      end

      def verify(msg32 : Bytes, signature65 : Bytes, pubkey : Bytes) : Bool
        return false unless msg32.size == 32 && signature65.size == 65 && (pubkey.size == 33 || pubkey.size == 65)
        internal_pub = Bytes.new(64)
        return false if LibSecp256k1.secp256k1_ec_pubkey_parse(@ctx, internal_pub, pubkey, pubkey.size) != 1
        internal_sig = Bytes.new(64)
        return false if LibSecp256k1.secp256k1_ecdsa_signature_parse_compact(@ctx, internal_sig, signature65[0, 64]) != 1
        LibSecp256k1.secp256k1_ecdsa_verify(@ctx, internal_sig, msg32, internal_pub) == 1
      end

      private def serialize_pubkey(internal : Bytes, compressed : Bool) : Bytes
        output = Bytes.new(compressed ? 33 : 65)
        outputlen = UInt64.new(output.size)
        flags = compressed ? LibSecp256k1::EC_COMPRESSED : LibSecp256k1::EC_UNCOMPRESSED
        if LibSecp256k1.secp256k1_ec_pubkey_serialize(@ctx, output, pointerof(outputlen), internal, flags) != 1
          raise Secp256k1Error.new("ec_pubkey_serialize failed")
        end
        output
      end
    end
  end
end
