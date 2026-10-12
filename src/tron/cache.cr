# Tron::Cache — 1:1 к tron.rb 1.2.4 (lib/tron/cache.cr): глобальный
# потокобезопасный кеш с TTL/max_stale и фолбэком на устаревшее значение.

module Tron
  class Cache
    private struct Entry
      getter value : JSON::Any
      getter cached_at : Float64
      getter ttl : Float64
      getter max_stale : Float64
      property hits : Int32
      property misses : Int32

      def initialize(@value, @cached_at, @ttl, @max_stale)
        @hits = 0
        @misses = 0
      end
    end

    @@store = {} of String => Entry
    @@mutex = Mutex.new
    @@total_hits = 0
    @@total_misses = 0
    @@total_fetches = 0

    # 1. Свежая запись (age < ttl) → возвращаем кеш
    # 2. Устаревшая (age < max_stale) → пробуем обновить; при ошибке отдаём старое
    # 3. Нет записи/слишком старая → выполняем блок и кешируем
    def self.fetch(key : String, ttl : Float64, max_stale : Float64, &block : -> JSON::Any) : JSON::Any
      @@mutex.synchronize do
        entry = @@store[key]?
        @@total_fetches += 1
        now = Time.utc.to_unix_f

        if entry && now - entry.cached_at < ttl
          @@store[key].hits += 1
          @@total_hits += 1
          entry.value
        elsif entry && now - entry.cached_at < max_stale
          begin
            new_value = block.call
            @@store[key] = Entry.new(new_value, now, ttl, max_stale)
            @@total_misses += 1
            new_value
          rescue
            # устаревшее значение как фолбэк
            @@store[key].misses += 1
            @@total_hits += 1
            entry.value
          end
        else
          new_value = block.call
          @@store[key] = Entry.new(new_value, now, ttl, max_stale)
          @@total_misses += 1
          new_value
        end
      end
    end

    def self.exists?(key : String) : Bool
      @@mutex.synchronize { @@store.has_key?(key) }
    end

    def self.delete(key : String) : Nil
      @@mutex.synchronize { @@store.delete(key) }
    end

    def self.clear : Nil
      @@mutex.synchronize { @@store.clear }
    end

    def self.size : Int32
      @@mutex.synchronize { @@store.size }
    end

    def self.stats(key : String) : JSON::Any?
      @@mutex.synchronize do
        entry = @@store[key]?
        next nil unless entry

        now = Time.utc.to_unix_f
        JSON::Any.new({
          "hits"       => JSON::Any.new(entry.hits),
          "misses"     => JSON::Any.new(entry.misses),
          "cached_at"  => json_float(entry.cached_at),
          "expires_at" => json_float(entry.cached_at + entry.ttl),
          "ttl"        => json_float(entry.ttl),
          "max_stale"  => json_float(entry.max_stale),
          "expired"    => JSON::Any.new(now - entry.cached_at >= entry.ttl),
        } of String => JSON::Any)
      end
    end

    def self.global_stats : JSON::Any
      @@mutex.synchronize do
        total_requests = @@total_fetches
        hit_rate = total_requests > 0 ? ((@@total_hits.to_f / total_requests) * 100).round(2) : 0.0

        JSON::Any.new({
          "total_hits"          => JSON::Any.new(@@total_hits),
          "total_misses"        => JSON::Any.new(@@total_misses),
          "total_fetches"       => JSON::Any.new(@@total_fetches),
          "hit_rate_percentage" => json_float(hit_rate),
          "cache_size"          => JSON::Any.new(@@store.size),
          "memory_keys"         => JSON::Any.new(@@store.size),
        } of String => JSON::Any)
      end
    end

    def self.reset_stats : Nil
      @@mutex.synchronize do
        @@total_hits = 0
        @@total_misses = 0
        @@total_fetches = 0
      end
    end

    private def self.json_float(v : Float64) : JSON::Any
      JSON.parse(v.to_json)
    end
  end
end

require "json"
