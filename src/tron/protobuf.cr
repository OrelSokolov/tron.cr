# Tron::Protobuf — 1:1 к tron.rb 1.2.4 (lib/tron/protobuf.rb).

require "json"
require "./protobuf/transaction_raw_serializer"

module Tron
  module Protobuf
    class TransactionSerializer
      def self.serialize_for_signing(transaction : JSON::Any) : Bytes
        TransactionRawSerializer.serialize(transaction)
      end
    end
  end
end
