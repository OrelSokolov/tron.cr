# Tron::Services::Contract — 1:1 к tron.rb 1.2.4 (lib/tron/services/contract.rb):
# взаимодействие со смарт-контрактами (read-only вызовы и транзакции).

require "json"
require "../utils/http"
require "../utils/address"
require "../abi"
require "./transaction"

module Tron
  module Services
    class Contract
      def initialize(@configuration : Configuration)
        @base_url = @configuration.base_url
        @transaction_service = Transaction.new(@configuration)
      end

      # State-changing вызов: создаёт и броадкастит транзакцию.
      def trigger_contract(contract_address : String, function : String, private_key : String,
                           parameters : Array(Abi::Value) = [] of Abi::Value,
                           fee_limit : Int64? = nil, call_value : Int64 = 0,
                           owner_address : String? = nil) : JSON::Any
        fee_limit ||= @configuration.fee_limit

        owner_address ||= derive_address_from_private_key(private_key)

        validate_address!(contract_address)
        validate_address!(owner_address)

        transaction = build_trigger_transaction(
          contract_address: contract_address,
          function: function,
          parameters: parameters,
          owner_address: owner_address,
          fee_limit: fee_limit,
          call_value: call_value
        )

        @transaction_service.sign_and_broadcast(transaction, private_key)
      end

      # Read-only вызов (без транзакции и смены состояния).
      def call_contract(contract_address : String, function : String,
                        parameters : Array(Abi::Value) = [] of Abi::Value,
                        owner_address : String? = nil) : String?
        owner_address ||= @configuration.default_address || "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"

        validate_address!(contract_address)

        endpoint = "#{@base_url}/wallet/triggerconstantcontract"

        encoded_data = Abi.encode_function_call(function, parameters)

        # поле 'data', не 'function_selector' (полный закодированный вызов)
        payload = {
          "contract_address" => JSON::Any.new(Utils::Address.to_hex(contract_address)),
          "data"             => JSON::Any.new(encoded_data),
          "owner_address"    => JSON::Any.new(Utils::Address.to_hex(owner_address)),
        } of String => JSON::Any

        cache_options = Utils::HTTP::CacheOptions.new
        cache_options.endpoint_type = "contract_call"
        cache_options.ttl = 60 # кеш на 1 минуту

        response = Utils::HTTP.post(endpoint, payload, cache_options)

        parse_constant_result(response)
      end

      def payment_processed?(contract_address : String, operator_address : String,
                             payment_id : String) : Bool
        result = call_contract(
          contract_address: contract_address,
          function: "isPaymentProcessed(address,bytes16)",
          parameters: [operator_address, payment_id] of Abi::Value
        )

        Abi.decode_output("bool", result.not_nil!).as(Bool)
      end

      def get_fee_destination(contract_address : String, operator_address : String) : String
        result = call_contract(
          contract_address: contract_address,
          function: "getFeeDestination(address)",
          parameters: [operator_address] of Abi::Value
        )

        Abi.decode_output("address", result.not_nil!).as(String)
      end

      def operator_registered?(contract_address : String, operator_address : String) : Bool
        result = call_contract(
          contract_address: contract_address,
          function: "isOperatorRegistered(address)",
          parameters: [operator_address] of Abi::Value
        )

        Abi.decode_output("bool", result.not_nil!).as(Bool)
      end

      private def build_trigger_transaction(contract_address : String, function : String,
                                            parameters : Array(Abi::Value), owner_address : String,
                                            fee_limit : Int64, call_value : Int64) : JSON::Any
        endpoint = "#{@base_url}/wallet/triggersmartcontract"

        encoded_data = Abi.encode_function_call(function, parameters)

        payload = {
          "contract_address" => JSON::Any.new(Utils::Address.to_hex(contract_address)),
          "data"             => JSON::Any.new(encoded_data),
          "fee_limit"        => JSON::Any.new(fee_limit),
          "call_value"       => JSON::Any.new(call_value),
          "owner_address"    => JSON::Any.new(Utils::Address.to_hex(owner_address)),
        } of String => JSON::Any

        response = Utils::HTTP.post(endpoint, payload)

        raise "Failed to create transaction: #{response}" unless truthy?(response["result"]?)

        response["transaction"]
      end

      private def parse_constant_result(response : JSON::Any) : String?
        return nil unless truthy?(response["result"]?)

        constant_result = response["constant_result"]?
        return nil if constant_result.nil? ||
                      (constant_result.as_a? && constant_result.as_a.empty?)

        constant_result.as_a.first.as_s
      end

      private def validate_address!(address : String) : Nil
        unless Utils::Address.validate(address)
          raise ArgumentError.new("Invalid TRON address: #{address}")
        end
      end

      private def derive_address_from_private_key(private_key : String) : String
        Tron::Key.new(private_key).address
      end

      private def truthy?(v : JSON::Any?) : Bool
        return false if v.nil?
        return false if (b = v.as_bool?) && !b
        true
      end
    end
  end
end

require "../key"
