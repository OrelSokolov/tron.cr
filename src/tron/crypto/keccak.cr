# Keccak-256 (оригинальный pre-NIST Keccak с доменом 0x01, как в
# Ethereum/TRON; НЕ sha3-256 с доменом 0x06). Oracle-контроль совпадения
# с Ruby-гемом keccak (digest/keccak): keccak256("") = c5d24601...

module Tron
  module Crypto
    RC = [
      0x0000000000000001_u64, 0x0000000000008082_u64, 0x800000000000808a_u64, 0x8000000080008000_u64,
      0x000000000000808b_u64, 0x0000000080000001_u64, 0x8000000080008081_u64, 0x8000000000008009_u64,
      0x000000000000008a_u64, 0x0000000000000088_u64, 0x0000000080008009_u64, 0x000000008000000a_u64,
      0x000000008000808b_u64, 0x800000000000008b_u64, 0x8000000000008089_u64, 0x8000000000008003_u64,
      0x8000000000008002_u64, 0x8000000000000080_u64, 0x000000000000800a_u64, 0x800000008000000a_u64,
      0x8000000080008081_u64, 0x8000000000008080_u64, 0x0000000080000001_u64, 0x8000000080008008_u64,
    ]

    ROTC = [
      1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62,
      18, 39, 61, 20, 44, 57, 23, 40, 64, 11, 29, 47, 59,
      55, 6, 20, 36, 63, 25, 46, 2, 43, 27, 61, 8, 34, 58, 14, 50,
      26, 62, 18, 46, 10, 54, 22, 58, 30, 6, 42, 14, 50, 26, 62, 30,
    ]

    PILN = [
      10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20,
      14, 22, 9, 6, 1, 5, 27, 36, 24, 17, 8, 44, 20, 14, 2, 11, 60, 6, 18,
      9, 30, 22, 44, 13, 61, 40, 49, 28, 57, 21, 5, 34, 23, 45, 24, 60, 47,
      48, 51, 41, 53, 32, 15, 63, 43,
    ]

    RATE = 136 # 1088 бит для keccak256

    def self.keccak256(data : Bytes) : Bytes
      st = Array(UInt64).new(25, 0_u64)

      # pad10*1 с доменом Keccak (0x01): 0x01 после данных, 0x80 в последнем
      # байте последнего блока.
      padded_size = (data.size // RATE + 1) * RATE
      padded = Bytes.new(padded_size)
      padded.copy_from(data)
      padded[data.size] ^= 0x01
      padded[padded_size - 1] ^= 0x80

      (padded_size // RATE).times do |block_index|
        offset = block_index * RATE
        (RATE // 8).times do |i|
          st[i] ^= load_u64(padded, offset + i * 8)
        end
        keccak_f(st)
      end

      digest = Bytes.new(32)
      4.times { |i| store_u64(st[i], digest, i * 8) }
      digest
    end

    def self.keccak256(data : String) : Bytes
      keccak256(data.to_slice)
    end

    def self.keccak256_hex(data : String | Bytes) : String
      keccak256(data).hexstring
    end

    # --- внутреннее ------------------------------------------------------------

    private def self.load_u64(block : Bytes, offset : Int32) : UInt64
      value = 0_u64
      8.times do |i|
        value |= block[offset + i].to_u64 << (8 * i)
      end
      value
    end

    private def self.store_u64(value : UInt64, block : Bytes, offset : Int32) : Nil
      8.times do |i|
        block[offset + i] = ((value >> (8 * i)) & 0xFF).to_u8
      end
    end

    private def self.keccak_f(st : Array(UInt64)) : Nil
      bc = Array(UInt64).new(5, 0_u64)
      24.times do |round|
        # Theta
        5.times do |i|
          bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20]
        end
        5.times do |i|
          t = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1)
          5.times do |j|
            st[j * 5 + i] ^= t
          end
        end
        # Rho and Pi
        t = st[1]
        24.times do |i|
          j = PILN[i]
          bc[0] = st[j]
          st[j] = rotl64(t, ROTC[i])
          t = bc[0]
        end
        # Chi
        5.times do |j|
          5.times { |i| bc[i] = st[j * 5 + i] }
          5.times do |i|
            st[j * 5 + i] = bc[i] ^ ((~bc[(i + 1) % 5]) & bc[(i + 2) % 5])
          end
        end
        # Iota
        st[0] ^= RC[round]
      end
    end

    private def self.rotl64(x : UInt64, n : Int32) : UInt64
      (x << n) | (x >> (64 - n))
    end
  end
end
