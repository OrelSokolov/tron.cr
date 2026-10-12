# Tron::Utils::RateLimiter — 1:1 к tron.rb 1.2.4 (lib/tron/utils/rate_limiter.rb):
# потокобезопасный rate limiter (не более N запросов за окно времени).

module Tron
  module Utils
    class RateLimiter
      def initialize(@max_requests : Int32, @time_window : Float64)
        @request_timestamps = Array(Float64).new
        @mutex = Mutex.new
      end

      def can_make_request? : Bool
        @mutex.synchronize do
          cleanup_old_requests
          @request_timestamps.size < @max_requests
        end
      end

      # Выполняет запрос, при необходимости засыпая, чтобы не превысить лимит.
      def execute_request : Float64
        @mutex.synchronize do
          cleanup_old_requests

          if @request_timestamps.size >= @max_requests
            oldest_time = @request_timestamps.first
            sleep_time = @time_window - (now - oldest_time)
            sleep sleep_time if sleep_time > 0
            cleanup_old_requests
          end

          @request_timestamps << now
          calculate_time_to_next_request
        end
      end

      private def now : Float64
        Time.utc.to_unix_f
      end

      private def cleanup_old_requests : Nil
        t = now
        @request_timestamps.reject! { |timestamp| t - timestamp > @time_window }
      end

      private def calculate_time_to_next_request : Float64
        return 0.0 if @request_timestamps.size <= 1

        t = now
        oldest_in_window = t - @time_window
        next_available = @request_timestamps.find { |ts| ts > oldest_in_window }
        return 0.0 unless next_available

        Math.max(0.0, @time_window - (t - next_available))
      end
    end
  end
end
