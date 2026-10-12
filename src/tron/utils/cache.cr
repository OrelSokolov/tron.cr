# Tron::Utils::Cache — 1:1 к tron.rb 1.2.4 (lib/tron/utils/cache.cr):
# простой потокобезопасный кеш со временем жизни записей.

module Tron
  module Utils
    class Cache(V)
      def initialize(@max_age : Float64 = 300.0) # 5 минут по умолчанию
        @cache = {} of String => V
        @timestamps = {} of String => Float64
        @mutex = Mutex.new
      end

      def get(key : String) : V?
        @mutex.synchronize do
          cleanup_expired_entries
          @cache[key]?
        end
      end

      def set(key : String, value : V) : Nil
        @mutex.synchronize do
          @cache[key] = value
          @timestamps[key] = Time.utc.to_unix_f
        end
      end

      def delete(key : String) : Nil
        @mutex.synchronize do
          @cache.delete(key)
          @timestamps.delete(key)
        end
      end

      def clear : Nil
        @mutex.synchronize do
          @cache.clear
          @timestamps.clear
        end
      end

      private def cleanup_expired_entries
        now = Time.utc.to_unix_f
        @timestamps.reject! { |_, timestamp| now - timestamp > @max_age }
        @cache.reject! { |key, _| !@timestamps.has_key?(key) }
      end
    end
  end
end
