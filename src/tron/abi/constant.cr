# Tron::Abi::Constant — 1:1 к tron.rb 1.2.4 (lib/tron/abi/constant.rb).

module Tron
  module Abi
    module Constant
      UINT_MAX = (BigInt.new(2) ** 256) - 1
      UINT_MIN = 0_i64
      INT_MAX  = (BigInt.new(2) ** 255) - 1
      INT_MIN  = -(BigInt.new(2) ** 255)

      BYTE_ZERO = Bytes[0]
      BYTE_ONE  = Bytes[1]
    end
  end
end
