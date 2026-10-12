# Tron::Services::Resources — 1:1 к tron.rb 1.2.4 (lib/tron/services/resources.rb):
# ресурсы аккаунта (bandwidth/energy/storage).

require "json"
require "../utils/http"
require "../utils/address"

module Tron
  module Services
    class Resources
      def initialize(@config : Configuration)
      end

      def get(address : String) : JSON::Any
        validate_address!(address)

        # сперва getaccountresource; при ошибке — фолбэк на getaccount
        begin
          get_account_resources(address)
        rescue e : Exception
          get_account_resources_fallback(address)
        end
      end

      private def get_account_resources(address : String) : JSON::Any
        url = "#{@config.base_url}/wallet/getaccountresource"
        headers = api_headers

        # как в tron.rb: строка-JSON уходит в Utils::HTTP.post и там
        # кодируется повторно (тело запроса — JSON-строка в кавычках)
        payload = {"address" => JSON::Any.new(address), "visible" => JSON::Any.new(true)}
          .to_json

        response = Utils::HTTP.post(url, payload)

        unless response.as_h?
          raise "Unexpected API response format for account resources"
        end

        return default_resources if response.as_h.has_key?("Error")

        free_net_limit = any_to_i(response["freeNetLimit"]?)
        free_net_used = any_to_i(response["freeNetUsed"]?)
        total_net_limit = any_to_i(response["TotalNetLimit"]?)
        energy_limit = any_to_i(response["EnergyLimit"]?)
        energy_used = any_to_i(response["EnergyUsed"]?)

        available_bandwidth = Math.max(0, free_net_limit - free_net_used)
        available_energy = Math.max(0, energy_limit - energy_used)
        available_total_net = Math.max(0, total_net_limit)

        JSON::Any.new({
          "bandwidth"              => JSON::Any.new(available_bandwidth),
          "bandwidthLimit"         => JSON::Any.new(free_net_limit),
          "energy"                 => JSON::Any.new(available_energy),
          "energyLimit"            => JSON::Any.new(energy_limit),
          "storage"                => JSON::Any.new(0_i64),
          "storageLimit"           => JSON::Any.new(0_i64),
          "totalFreeBandwidth"     => JSON::Any.new(available_total_net),
          "totalFreeBandwidthLimit" => JSON::Any.new(total_net_limit),
        } of String => JSON::Any)
      end

      private def get_account_resources_fallback(address : String) : JSON::Any
        url = "#{@config.base_url}/wallet/getaccount"
        headers = api_headers

        payload = {"address" => JSON::Any.new(address), "visible" => JSON::Any.new(true)}
          .to_json

        response = Utils::HTTP.post(url, payload)

        unless response.as_h? && response.as_h.has_key?("data")
          raise "Unexpected response format from getaccount endpoint"
        end

        account_data = response["data"].as_a.first? || JSON::Any.new({} of String => JSON::Any)

        free_net_limit = any_to_i(account_data["freeNetLimit"]?)
        free_net_used = any_to_i(account_data["freeNetUsed"]?)
        energy_limit = any_to_i(account_data["EnergyLimit"]?)
        energy_used = any_to_i(account_data["EnergyUsed"]?)
        storage_limit = any_to_i(account_data["StorageLimit"]?)
        storage_used = any_to_i(account_data["StorageUsed"]?)

        JSON::Any.new({
          "bandwidth"              => JSON::Any.new(Math.max(0, free_net_limit - free_net_used)),
          "bandwidthLimit"         => JSON::Any.new(free_net_limit),
          "energy"                 => JSON::Any.new(Math.max(0, energy_limit - energy_used)),
          "energyLimit"            => JSON::Any.new(energy_limit),
          "storage"                => JSON::Any.new(Math.max(0, storage_limit - storage_used)),
          "storageLimit"           => JSON::Any.new(storage_limit),
          "totalFreeBandwidth"     => JSON::Any.new(0_i64),
          "totalFreeBandwidthLimit" => JSON::Any.new(0_i64),
        } of String => JSON::Any)
      end

      private def validate_address!(address : String) : Nil
        unless Utils::Address.validate(address)
          raise ArgumentError.new("Invalid TRON address: #{address}")
        end
      end

      private def api_headers : Hash(String, String)
        headers = {"accept" => "application/json", "Content-Type" => "application/json"} of String => String
        headers["TRON-PRO-API-KEY"] = @config.api_key.as(String) if @config.api_key
        headers
      end

      private def default_resources : JSON::Any
        JSON::Any.new({
          "bandwidth"              => JSON::Any.new(0_i64),
          "bandwidthLimit"         => JSON::Any.new(0_i64),
          "energy"                 => JSON::Any.new(0_i64),
          "energyLimit"            => JSON::Any.new(0_i64),
          "storage"                => JSON::Any.new(0_i64),
          "storageLimit"           => JSON::Any.new(0_i64),
          "totalFreeBandwidth"     => JSON::Any.new(0_i64),
          "totalFreeBandwidthLimit" => JSON::Any.new(0_i64),
        } of String => JSON::Any)
      end

      private def any_to_i(v : JSON::Any?) : Int64
        return 0_i64 unless v
        if s = v.as_s?
          s.to_i64? || 0_i64
        elsif i = v.as_i64?
          i.to_i64
        elsif f = v.as_f?
          f.to_i64
        else
          0_i64
        end
      end
    end
  end
end
