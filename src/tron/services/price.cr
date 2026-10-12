# Tron::Services::Price — 1:1 к tron.rb 1.2.4 (lib/tron/services/price.rb).

require "json"
require "../utils/http"
require "../utils/cache"
require "../utils/rate_limiter"

module Tron
  module Services
    class Price
      def initialize(@config : Configuration)
        @cache = @config.cache_enabled ? Utils::Cache(String).new(@config.cache_ttl.to_f) : nil
        @rate_limiter = Utils::RateLimiter.new(1, 1.0)
        @cache_hits = 0
        @cache_misses = 0
      end

      getter cache_hits : Int32
      getter cache_misses : Int32

      # Информация о цене токена (сырой ответ Tronscan).
      def get_token_price(token : String = "trx") : JSON::Any?
        cache_key = cache_key_for(token)

        if @config.cache_enabled && (cached = @cache.try &.get(cache_key))
          @cache_hits += 1
          return JSON.parse(cached)
        end

        @cache_misses += 1

        @rate_limiter.execute_request

        url = "#{@config.tronscan_base_url}/api/token/price?token=#{token}"
        headers = tronscan_headers

        response = Utils::HTTP.get(url, headers)

        unless response.as_h?
          raise "Unexpected API response format for token price"
        end

        @cache.try &.set(cache_key, response.to_json) if @config.cache_enabled

        response
      rescue e : Exception
        if @config.strict_mode
          raise e
        else
          STDERR.puts "Warning: Could not fetch price for #{token}: #{e.message}"
          nil
        end
      end

      def get_all_prices : JSON::Any?
        url = "#{@config.tronscan_base_url}/api/getAssetWithPriceList"
        headers = tronscan_headers

        response = Utils::HTTP.get(url, headers)

        unless response.as_h?
          raise "Unexpected API response format for price list"
        end

        response
      rescue e : Exception
        if @config.strict_mode
          raise e
        else
          STDERR.puts "Warning: Could not fetch token price list: #{e.message}"
          nil
        end
      end

      # USD-цена токена (Float64) или nil.
      def get_token_price_usd(token : String) : Float64?
        cache_key = "#{cache_key_for(token)}:usd"

        if @config.cache_enabled && (cached = @cache.try &.get(cache_key))
          @cache_hits += 1
          return cached.to_f64
        end

        @cache_misses += 1

        price_data = get_token_price(token)
        return nil unless price_data.try &.as_h?

        result = if (v = price_data.not_nil!["price_in_usd"]?)
                   any_to_f(v)
                 elsif (v = price_data.not_nil!["priceInUsd"]?)
                   any_to_f(v)
                 else
                   nil
                 end

        if @config.cache_enabled && result
          @cache.try &.set(cache_key, result.to_json)
        end

        result
      end

      # USD-стоимость баланса токена.
      def get_token_value_usd(balance : String | Float64, token : String) : Float64?
        price = get_token_price_usd(token)
        if price
          balance_num = balance.is_a?(String) ? balance.to_f : balance.as(Float64)
          balance_num * price
        else
          nil
        end
      end

      def get_multiple_token_prices(tokens : Array(String)) : Hash(String, Float64?)
        prices = {} of String => Float64?
        tokens.each_with_index do |token, index|
          sleep(0.1) if index > 0
          begin
            prices[token] = get_token_price_usd(token)
          rescue e : Exception
            if @config.strict_mode
              raise e
            else
              STDERR.puts "Warning: Could not fetch price for #{token}: #{e.message}"
              prices[token] = nil
            end
          end
        end
        prices
      end

      def format_price(price : Float64?, currency : String = "USD") : String
        if price.nil?
          "(price unavailable)"
        elsif price < 0.0001
          "#{sprintf("%.8f", price)} #{currency}"
        elsif price < 1
          "#{sprintf("%.6f", price)} #{currency}"
        else
          "#{sprintf("%.4f", price)} #{currency}"
        end
      end

      def cache_stats : JSON::Any
        total = @cache_hits + @cache_misses
        hit_rate = total > 0 ? ((@cache_hits.to_f / total) * 100).round(2) : 0.0
        JSON::Any.new({
          "hits"     => JSON::Any.new(@cache_hits),
          "misses"   => JSON::Any.new(@cache_misses),
          "total"    => JSON::Any.new(total),
          "hit_rate" => JSON.parse(hit_rate.to_json),
        } of String => JSON::Any)
      end

      def clear_cache : Nil
        @cache.try &.clear
        @cache_hits = 0
        @cache_misses = 0
      end

      private def cache_key_for(token : String) : String
        "price:#{token.downcase}:#{@config.network}"
      end

      private def tronscan_headers : Hash(String, String)
        headers = {"accept" => "application/json"} of String => String
        headers["TRON-PRO-API-KEY"] = @config.tronscan_api_key.as(String) if @config.tronscan_api_key
        headers
      end

      private def any_to_f(v : JSON::Any?) : Float64
        return 0.0 unless v
        if s = v.as_s?
          s.to_f? || 0.0
        elsif i = v.as_i?
          i.to_f
        elsif f = v.as_f?
          f
        else
          0.0
        end
      end
    end
  end
end
