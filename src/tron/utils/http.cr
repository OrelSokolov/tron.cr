# Tron::Utils::HTTP — 1:1 к tron.rb 1.2.4 (lib/tron/utils/http.rb): HTTP-слой
# с кешированием GET и обработкой ошибок.
#
# Отличие от Ruby-версии: реальный сетевой вызов вынесен в транспорт
# (@@transport), который можно подменить в тестах (оракул-спек играет роль
# перехваченного Net::HTTP и возвращает заготовленные ответы).

require "http/client"
require "json"
require "digest"

module Tron
  module Utils
    module HTTP
      # TTL по типам эндпоинтов (в секундах), см. ENDPOINT_TTL в tron.rb
      ENDPOINT_TTL = {
        "balance"    => {ttl: 300, max_stale: 600},
        "token_info" => {ttl: 900, max_stale: 1800},
        "price"      => {ttl: 60, max_stale: 120},
        "resources"  => {ttl: 300, max_stale: 600},
        "default"    => {ttl: 300, max_stale: 600},
      } of String => NamedTuple(ttl: Int32, max_stale: Int32)

      # Опции кеширования запроса (аналог cache_options-хеша в tron.rb).
      class CacheOptions
        property enabled : Bool? = nil
        property ttl : Int32? = nil
        property max_stale : Int32? = nil
        property endpoint_type : String? = nil

        def initialize
        end

        def enabled_false? : Bool
          @enabled == false
        end

        def custom_ttl? : Bool
          !@ttl.nil? && !@max_stale.nil?
        end
      end

      class Request
        getter method : String # "GET" | "POST"
        getter url : String
        getter body : String?
        getter headers : Hash(String, String)

        def initialize(@method, @url, @body, @headers)
        end
      end

      @@transport : Proc(Request, String)? = nil

      def self.transport=(t : Proc(Request, String)?) : Nil
        @@transport = t
      end

      def self.transport? : Proc(Request, String)?
        @@transport
      end

      # GET с опциональным кешированием. Возвращает разобранный JSON.
      def self.get(url : String, headers : Hash(String, String) = Hash(String, String).new,
                   cache_options : CacheOptions = CacheOptions.new) : JSON::Any
        if should_use_cache?(cache_options)
          cache_key = generate_cache_key("GET", url, headers)
          ttl_config = get_ttl_config(cache_options)

          Tron::Cache.fetch(cache_key, ttl_config[:ttl].to_f, ttl_config[:max_stale].to_f) do
            make_request("GET", url, nil, headers)
          end
        else
          make_request("GET", url, nil, headers)
        end
      end

      # POST (мутации не кешируются). Возвращает разобранный JSON.
      # Как и в tron.rb, заголовки вызова не учитываются: ставятся
      # Content-Type и TRON-PRO-API-KEY из глобальной конфигурации.
      def self.post(url : String, payload : String | Hash(String, JSON::Any),
                    cache_options : CacheOptions = CacheOptions.new) : JSON::Any
        headers = {"Content-Type" => "application/json"} of String => String
        headers["TRON-PRO-API-KEY"] = Tron.configuration.api_key.as(String) if Tron.configuration.api_key

        request = Request.new("POST", url, payload.to_json, headers)
        body = perform(request)

        JSON.parse(body)
      end

      def self.clear_cache(url : String, headers : Hash(String, String) = Hash(String, String).new) : Nil
        Tron::Cache.delete(generate_cache_key("GET", url, headers))
      end

      def self.cache_stats(url : String, headers : Hash(String, String) = Hash(String, String).new) : JSON::Any?
        Tron::Cache.stats(generate_cache_key("GET", url, headers))
      end

      private def self.should_use_cache?(cache_options : CacheOptions) : Bool
        return false if cache_options.enabled_false?
        Tron.configuration.cache_enabled
      end

      private def self.get_ttl_config(cache_options : CacheOptions) : NamedTuple(ttl: Int32, max_stale: Int32)
        if cache_options.custom_ttl?
          return {ttl: cache_options.ttl.as(Int32), max_stale: cache_options.max_stale.as(Int32)}
        end

        if et = cache_options.endpoint_type
          cfg = ENDPOINT_TTL[et]?
          return cfg if cfg
        end

        config = Tron.configuration
        {ttl: config.cache_ttl, max_stale: config.cache_max_stale}
      end

      private def self.generate_cache_key(method : String, url : String,
                                          headers : Hash(String, String)) : String
        # method + url + значимые заголовки (без user-agent), отсортированные
        relevant = headers.reject { |k, _| k.downcase == "user-agent" }.to_a.sort_by { |k, _| k }
        Digest::SHA256.hexdigest(([method, url] + relevant.flatten).join("\u0000"))
      end

      private def self.make_request(method : String, url : String, body : String?,
                                    headers : Hash(String, String)) : JSON::Any
        request = Request.new(method, url, body, headers)
        response_body = perform(request)

        begin
          json_response = JSON.parse(response_body)
          unless json_response.as_h? || json_response.as_a?
            raise "Invalid response format: expected JSON object or array"
          end
          json_response
        rescue JSON::ParseException
          raise "Invalid JSON response: #{response_body}"
        rescue e : ArgumentError
          raise "HTTP Error: #{e.message}"
        end
      rescue e : Exception
        raise "HTTP Error: #{e.message}"
      end

      # Выполняет запрос через подменяемый транспорт (тест) или HTTP::Client.
      private def self.perform(request : Request) : String
        if t = @@transport
          return t.call(request)
        end

        uri = URI.parse(request.url)
        client = ::HTTP::Client.new(uri)
        client.read_timeout = Tron.configuration.timeout

        headers = ::HTTP::Headers.new
        request.headers.each { |k, v| headers[k] = v }

        response = if request.method == "GET"
                     client.get(uri.request_target, headers)
                   else
                     client.post(uri.request_target, headers, request.body || "")
                   end

        unless response.status.success?
          raise "API Error: #{response.status.code} - #{response.body}"
        end
        response.body
      rescue e : IO::Error | Socket::Error | OpenSSL::Error | ArgumentError
        raise "HTTP Error: #{e.message}"
      end
    end
  end
end

require "../cache"
require "../configuration"
