# Tron::Configuration — 1:1 к tron.rb 1.2.4 (lib/tron/configuration.rb).

module Tron
  class Configuration
    property api_key : String? = nil
    property tronscan_api_key : String? = nil
    property timeout : Int32 = 30
    property base_url : String = "https://api.trongrid.io"
    property tronscan_base_url : String = "https://apilist.tronscanapi.com"
    property strict_mode : Bool = false
    property cache_enabled : Bool = true
    property cache_ttl : Int32 = 300       # 5 минут по умолчанию
    property cache_max_stale : Int32 = 600 # 10 минут max stale
    property default_address : String? = nil
    property fee_limit : Int64 = 100_000_000 # 100 TRX по умолчанию
    getter network : String

    def initialize
      @network = "mainnet"
      setup_urls
    end

    def network=(network : String) : Nil
      @network = network
      setup_urls
    end

    # Аналог Configuration#cache= из tron.rb.
    def set_cache(enabled : Bool? = nil, ttl : Int32? = nil, max_stale : Int32? = nil) : Nil
      @cache_enabled = enabled unless enabled.nil?
      @cache_ttl = ttl unless ttl.nil?
      @cache_max_stale = max_stale unless max_stale.nil?
    end

    def disable_cache : Nil
      @cache_enabled = false
    end

    private def setup_urls : Nil
      case @network
      when "mainnet"
        @base_url = "https://api.trongrid.io"
        @tronscan_base_url = "https://apilist.tronscanapi.com"
      when "shasta"
        @base_url = "https://api.shasta.trongrid.io"
        @tronscan_base_url = "https://shasta.tronscan.org"
      when "nile"
        @base_url = "https://nile.trongrid.io"
        @tronscan_base_url = "https://nileapi.tronscan.org"
      else
        @base_url = "https://api.trongrid.io"
        @tronscan_base_url = "https://apilist.tronscanapi.com"
      end
    end
  end
end
