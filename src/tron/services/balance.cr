# Tron::Services::Balance — 1:1 к tron.rb 1.2.4 (lib/tron/services/balance.rb):
# TRX- и TRC20-балансы адресов.

require "json"
require "../utils/http"
require "../utils/address"
require "../utils/cache"
require "../utils/rate_limiter"

module Tron
  module Services
    class Balance
      def initialize(@config : Configuration)
        @cache = @config.cache_enabled ? Utils::Cache(String).new(@config.cache_ttl.to_f) : nil
        @rate_limiter = Utils::RateLimiter.new(1, 1.0)
        @cache_hits = 0
        @cache_misses = 0
      end

      getter cache_hits : Int32
      getter cache_misses : Int32

      # TRX-баланс как отформатированная строка ("1500.000000").
      def get_trx(address : String) : String
        validate_address!(address)

        cache_key = "balance:trx:#{address}:#{@config.network}"

        if @config.cache_enabled && (cached = @cache.try &.get(cache_key))
          @cache_hits += 1
          return cached
        end

        @cache_misses += 1

        @rate_limiter.execute_request

        url = "#{@config.base_url}/v1/accounts/#{address}"
        headers = api_headers

        response = Utils::HTTP.get(url, headers)

        raise "Unexpected API response format" unless response.as_h?
        raise "Missing 'data' field in response" unless response.as_h.has_key?("data")
        raise "Invalid 'data' format in response" unless response["data"].as_a?

        data = response["data"].as_a
        if data.empty?
          result = "0.000000"
          @cache.try &.set(cache_key, result) if @config.cache_enabled
          return result
        end

        account_data = data.first
        raise "Invalid account data format" unless account_data.as_h?

        raw_balance = account_data["balance"]? || JSON::Any.new(0)
        result = format_balance(raw_balance, 6)

        @cache.try &.set(cache_key, result) if @config.cache_enabled

        result
      end

      # TRC20-токены адреса (Tronscan для mainnet/nile, TronGrid для shasta).
      def get_trc20_tokens(address : String, strict : Bool = false) : JSON::Any
        validate_address!(address)

        cache_key = "balance:trc20:#{address}:#{@config.network}"

        if @config.cache_enabled && (cached = @cache.try &.get(cache_key))
          @cache_hits += 1
          return JSON.parse(cached)
        end

        @cache_misses += 1

        @rate_limiter.execute_request

        result = @config.network == "shasta" ? get_trc20_from_trongrid(address) : get_trc20_from_tronscan(address)

        @cache.try &.set(cache_key, result.to_json) if @config.cache_enabled

        result
      end

      private def get_trc20_from_tronscan(address : String, strict : Bool = false) : JSON::Any
        url = "#{@config.tronscan_base_url}/api/account/wallet?address=#{address}&asset_type=1"
        headers = tronscan_headers

        response = Utils::HTTP.get(url, headers)

        raise "Unexpected API response format for TRC20 tokens" unless response.as_h?
        raise "Missing 'data' field in TRC20 response" unless response.as_h.has_key?("data")
        raise "Invalid 'data' format in TRC20 response" unless response["data"].as_a?

        tokens = response["data"].as_a.select do |token|
          token["token_type"]?.try(&.as_i?) == 20 && any_to_f(token["balance"]?) > 0
        end.map do |token|
          validate_token_data!(token)
          symbol = if (abbr = token["token_abbr"]?.try &.as_s?)
                     abbr
                   else
                     token["token_name"].as_s
                   end
          decimals = if (d = token["token_decimal"]?).nil?
                       6
                     else
                       any_to_i(d)
                     end
          JSON::Any.new({
            "symbol"    => JSON::Any.new(symbol),
            "name"      => token["token_name"],
            "balance"   => json_float(any_to_f(token["balance"]?)),
            "decimals"  => JSON::Any.new(decimals),
            "address"   => token["token_id"],
          } of String => JSON::Any)
        end

        JSON::Any.new(tokens)
      end

      private def get_trc20_from_trongrid(address : String) : JSON::Any
        url = "#{@config.base_url}/v1/accounts/#{address}"
        headers = api_headers

        response = Utils::HTTP.get(url, headers)

        raise "Unexpected API response format" unless response.as_h?
        raise "Missing 'data' field in response" unless response.as_h.has_key?("data")
        raise "Invalid 'data' format in response" unless response["data"].as_a?

        data = response["data"].as_a
        return JSON::Any.new([] of JSON::Any) if data.empty?

        account_data = data.first
        raise "Invalid account data format" unless account_data.as_h?

        trc20_data = account_data["trc20"]? || JSON::Any.new([] of JSON::Any)
        return JSON::Any.new([] of JSON::Any) unless trc20_data.as_a?

        tokens = [] of JSON::Any
        trc20_data.as_a.each do |token_hash|
          token_hash.as_h.each do |token_address, raw_amount|
            tokens << JSON::Any.new({
              "symbol"     => JSON::Any.new(nil),
              "name"       => JSON::Any.new(nil),
              "balance"    => JSON::Any.new(nil),
              "raw_amount" => JSON::Any.new(any_to_i(raw_amount)),
              "decimals"   => JSON::Any.new(nil),
              "address"    => JSON::Any.new(token_address),
            } of String => JSON::Any)
          end
        end

        # как в tron.rb: .select { |token| token[:raw_amount] > 0 }
        JSON::Any.new(tokens.select { |token| token["raw_amount"].as_i64 > 0 })
      end

      def cache_stats : JSON::Any
        total = @cache_hits + @cache_misses
        hit_rate = total > 0 ? ((@cache_hits.to_f / total) * 100).round(2) : 0.0
        JSON::Any.new({
          "hits"     => JSON::Any.new(@cache_hits),
          "misses"   => JSON::Any.new(@cache_misses),
          "total"    => JSON::Any.new(total),
          "hit_rate" => json_float(hit_rate),
        } of String => JSON::Any)
      end

      def clear_cache : Nil
        @cache.try &.clear
        @cache_hits = 0
        @cache_misses = 0
      end

      private def validate_token_data!(token : JSON::Any) : Nil
        unless token.as_h?
          raise "Invalid token data format: expected hash"
        end

        ["token_type", "balance"].each do |field|
          unless token.as_h.has_key?(field)
            raise "Missing required field '#{field}' in token data: #{token}"
          end
        end
      end

      private def validate_address!(address : String) : Nil
        unless Utils::Address.validate(address)
          raise ArgumentError.new("Invalid TRON address: #{address}")
        end
      end

      # Форматирование сырого баланса: whole.fraction с decimals знаками.
      private def format_balance(raw_balance : JSON::Any, decimals : Int32) : String
        balance = any_to_i(raw_balance).to_big_i
        divisor = BigInt.new(10) ** decimals
        whole = balance // divisor
        fraction = balance % divisor
        "#{whole}.#{fraction.to_s.rjust(decimals, '0')}"
      end

      private def api_headers : Hash(String, String)
        headers = {"accept" => "application/json"} of String => String
        headers["TRON-PRO-API-KEY"] = @config.api_key.as(String) if @config.api_key
        headers
      end

      private def tronscan_headers : Hash(String, String)
        headers = {"accept" => "application/json"} of String => String
        headers["TRON-PRO-API-KEY"] = @config.tronscan_api_key.as(String) if @config.tronscan_api_key
        headers
      end

      # JSON::Any → Float64 (как .to_f в Ruby: строки, числа, nil → 0.0).
      private def any_to_f(v : JSON::Any?) : Float64
        return 0.0 unless v
        if s = v.as_s?
          s.to_f? || 0.0
        elsif i = v.as_i64?
          i.to_f
        elsif f = v.as_f?
          f
        else
          0.0
        end
      end

      # JSON::Any → Int64 (как .to_i в Ruby).
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

      private def json_float(v : Float64) : JSON::Any
        JSON.parse(v.to_json)
      end
    end
  end
end
