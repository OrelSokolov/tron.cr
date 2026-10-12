# Tron::Utils::ChainId — 1:1 к tron.rb 1.2.4 (lib/tron/utils/chain_id.rb).

module Tron
  module Utils
    module ChainId
      MAINNET = 0x2b6653dc # 728126428
      NILE    = 0xcd8690dc # 3448148188

      def self.for_network(network : String) : Int64
        case network
        when "mainnet" then MAINNET.to_i64
        when "nile"    then NILE.to_i64
        else
          raise ArgumentError.new("Unknown network: #{network}. Supported networks: :mainnet, :nile")
        end
      end

      def self.from_client(client : Tron::Client) : Int64
        for_network(client.configuration.network)
      end
    end
  end
end
