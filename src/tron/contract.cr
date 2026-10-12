# Tron::Contract — 1:1 к tron.rb 1.2.4 (lib/tron/contract.cr): обёртка над
# смарт-контрактом по его ABI.

require "json"
require "./abi"
require "./client"

module Tron
  class Contract
    getter address : String
    getter abi : JSON::Any

    def initialize(@address : String, @abi_json : JSON::Any, @configuration : Configuration)
      @abi = @abi_json
      @client = Client.new(
        api_key: @configuration.api_key,
        tronscan_api_key: @configuration.tronscan_api_key,
        network: @configuration.network,
        timeout: @configuration.timeout
      )

      @functions = {} of String => JSON::Any
      parse_abi
    end

    def self.from_abi(abi : JSON::Any, address : String,
                      configuration : Configuration? = nil) : Contract
      config = configuration || Client.configuration
      new(address, abi, config)
    end

    # Read-only вызов функции контракта.
    def call_function(function_name : String, *args : Abi::Value) : Abi::Value?
      function_abi = @functions[function_name]?
      raise "Function #{function_name} not found in ABI" unless function_abi

      encoded_data = encode_function_call(function_abi, args.to_a)

      result = @client.contract_service.call_contract(
        contract_address: @address,
        function: encoded_data,
        parameters: [] of Abi::Value
      )

      decode_function_output(function_abi, result)
    end

    # State-changing вызов функции контракта.
    def execute_function(function_name : String, *args : Abi::Value, private_key : String,
                         fee_limit : Int64 = 100_000_000, call_value : Int64 = 0) : JSON::Any
      function_abi = @functions[function_name]?
      raise "Function #{function_name} not found in ABI" unless function_abi

      encoded_data = encode_function_call(function_abi, args.to_a)

      @client.contract_service.trigger_contract(
        contract_address: @address,
        function: encoded_data,
        parameters: [] of Abi::Value,
        private_key: private_key,
        fee_limit: fee_limit,
        call_value: call_value
      )
    end

    private def parse_abi : Nil
      @abi.as_a.each do |item|
        next unless item["type"]?.try &.as_s? == "function"
        @functions[item["name"].as_s] = item
      end
    end

    private def encode_function_call(function_abi : JSON::Any, args : Array(Abi::Value)) : String
      inputs = (function_abi["inputs"]? || JSON::Any.new([] of JSON::Any)).as_a
      parsed_types = inputs.map { |input| Abi::Type.parse(input["type"].as_s) }

      encoded_args = Bytes.empty
      args.each_with_index do |arg, idx|
        encoded_args += Abi::Encoder.type(parsed_types[idx], arg)
      end

      signature = "#{function_abi["name"].as_s}(#{inputs.map { |input| input["type"].as_s }.join(",")})"

      function_selector = Crypto.keccak256(signature)[0, 4].hexstring

      function_selector + Abi::Util.bin_to_hex(encoded_args)
    end

    private def decode_function_output(function_abi : JSON::Any, output_data : String?) : Abi::Value?
      outputs = (function_abi["outputs"]? || JSON::Any.new([] of JSON::Any)).as_a
      return nil if outputs.empty?

      output_types = outputs.map { |output| Abi::Type.parse(output["type"].as_s) }

      # упрощение как в tron.rb: только первый выход
      Abi::Decoder.type(output_types.first,
        Abi::Util.hex_to_bin(output_data.not_nil!))
    end
  end
end

require "./crypto/keccak"
