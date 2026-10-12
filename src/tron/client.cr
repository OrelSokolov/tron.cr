# Tron::Client — 1:1 к tron.rb 1.2.4 (lib/tron/client.rb): главный клиент
# для работы с TRON-блокчейном (балансы, ресурсы, цены, контракты).

require "json"
require "./configuration"
require "./services/balance"
require "./services/resources"
require "./services/price"
require "./services/contract"
require "./services/transaction"
require "./utils/address"

module Tron
  class Client
    getter configuration : Configuration

    def initialize(api_key : String? = nil, tronscan_api_key : String? = nil,
                   network : String? = nil, timeout : Int32? = nil,
                   cache_enabled : Bool? = nil, cache_ttl : Int32? = nil,
                   cache_max_stale : Int32? = nil, default_address : String? = nil,
                   fee_limit : Int64? = nil)
      @configuration = Configuration.new

      @configuration.api_key = api_key if api_key
      @configuration.tronscan_api_key = tronscan_api_key if tronscan_api_key
      @configuration.network = network if network
      @configuration.timeout = timeout if timeout
      @configuration.cache_enabled = cache_enabled if cache_enabled
      @configuration.cache_ttl = cache_ttl if cache_ttl
      @configuration.cache_max_stale = cache_max_stale if cache_max_stale
      @configuration.default_address = default_address if default_address
      @configuration.fee_limit = fee_limit if fee_limit

      # env-фолбэки, если не задано опциями
      @configuration.api_key ||= ENV["TRONGRID_API_KEY"]?
      @configuration.tronscan_api_key ||= ENV["TRONSCAN_API_KEY"]?
    end

    def self.configure(&block : Configuration -> _) : Nil
      yield configuration
    end

    @@default_configuration : Configuration? = nil

    def self.configuration : Configuration
      @@default_configuration ||= Configuration.new
    end

    @balance_service : Services::Balance?
    @resources_service : Services::Resources?
    @price_service : Services::Price?
    @contract_service : Services::Contract?
    @transaction_service : Services::Transaction?

    def balance_service : Services::Balance
      @balance_service ||= Services::Balance.new(@configuration)
    end

    def resources_service : Services::Resources
      @resources_service ||= Services::Resources.new(@configuration)
    end

    def price_service : Services::Price
      @price_service ||= Services::Price.new(@configuration)
    end

    def contract_service : Services::Contract
      @contract_service ||= Services::Contract.new(@configuration)
    end

    def transaction_service : Services::Transaction
      @transaction_service ||= Services::Transaction.new(@configuration)
    end

    # Баланс кошелька: TRX + TRC20-токены.
    def get_wallet_balance(address : String, strict : Bool = false) : JSON::Any
      validate_address!(address)

      JSON::Any.new({
        "address"     => JSON::Any.new(address),
        "trx_balance" => JSON::Any.new(balance_service.get_trx(address)),
        "trc20_tokens" => balance_service.get_trc20_tokens(address, strict),
      } of String => JSON::Any)
    end

    # Полная информация об аккаунте: балансы + ресурсы.
    def get_full_account_info(address : String, strict : Bool = false) : JSON::Any
      validate_address!(address)

      JSON::Any.new({
        "address"      => JSON::Any.new(address),
        "trx_balance"  => JSON::Any.new(balance_service.get_trx(address)),
        "trc20_tokens" => balance_service.get_trc20_tokens(address, strict),
        "resources"    => resources_service.get(address),
      } of String => JSON::Any)
    end

    # Портфель: балансы, конвертированные в USD.
    def get_wallet_portfolio(address : String, include_zero_balances : Bool = false) : JSON::Any
      validate_address!(address)

      # Шаг 1: все балансы (TRX + TRC20)
      wallet_data = get_wallet_balance(address)

      tokens = [] of JSON::Any

      # Шаг 2: TRX (нативный токен)
      trx_balance = wallet_data["trx_balance"].as_s.to_f
      if trx_balance > 0 || include_zero_balances
        trx_price = price_service.get_token_price_usd("trx")
        tokens << JSON::Any.new({
          "symbol"        => JSON::Any.new("TRX"),
          "name"          => JSON::Any.new("Tronix"),
          "token_balance" => json_float(trx_balance),
          "decimals"      => JSON::Any.new(6),
          "address"       => JSON::Any.new(nil),
          "price_usd"     => json_opt_float(trx_price),
          "usd_value"     => json_opt_float(trx_price ? trx_balance * trx_price.not_nil! : nil),
        } of String => JSON::Any)
      end

      # Шаг 3: TRC20-токены
      wallet_data["trc20_tokens"].as_a.each do |token|
        token_h = token.as_h

        # TronGrid-токены: raw_amount без balance — конвертация по decimals
        raw_amount = token_h["raw_amount"]?
        balance_any = token_h["balance"]?
        if raw_amount && !truthy_json?(balance_any)
          decimals = token_h["decimals"]?
          next unless decimals

          balance_any = JSON.parse((any_to_i(raw_amount) / (10 ** any_to_i(decimals)).to_f64).to_json)
        end

        balance = any_to_f(balance_any)
        next if balance <= 0 && !include_zero_balances

        symbol = token_h["symbol"]?.try &.as_s? || ""
        price_usd = price_service.get_token_price_usd(symbol.downcase)

        tokens << JSON::Any.new({
          "symbol"        => JSON::Any.new(token_h["symbol"]?.try &.as_s? || "UNKNOWN"),
          "name"          => JSON::Any.new(token_h["name"]?.try &.as_s? || "Unknown Token"),
          "token_balance" => json_float(balance),
          "decimals"      => json_opt(token_h["decimals"]?),
          "address"       => json_opt(token_h["address"]?),
          "price_usd"     => json_opt_float(price_usd),
          "usd_value"     => json_opt_float(price_usd ? balance * price_usd.not_nil! : nil),
          "raw_amount"    => json_opt(raw_amount),
        } of String => JSON::Any)
      end

      # Шаг 4: суммарная стоимость
      total_value_usd = tokens.sum { |t| any_to_f(t["usd_value"]?) }

      # Шаг 5: сортировка по убыванию стоимости
      tokens.sort_by! { |t| -any_to_f(t["usd_value"]?) }

      JSON::Any.new({
        "address"         => JSON::Any.new(address),
        "total_value_usd" => json_float(total_value_usd),
        "tokens"          => JSON::Any.new(tokens),
      } of String => JSON::Any)
    end

    def cache_enabled? : Bool
      configuration.cache_enabled
    end

    # ВАЖНО (баг 1:1 из tron.rb 1.2.4): Services::Balance#cache_stats в
    # оригинале объявлен после `private`, поэтому Client#cache_stats падает с
    # NoMethodError. Порт воспроизводит это поведение.
    def cache_stats : JSON::Any
      price_service.cache_stats # price-статистика доступна
      raise Exception.new("private method 'cache_stats' called for an instance of Tron::Services::Balance")
    end

    def clear_cache : Nil
      price_service.clear_cache
      # balance#clear_cache в tron.rb 1.2.4 тоже приватный — тот же баг
      raise Exception.new("private method 'clear_cache' called for an instance of Tron::Services::Balance")
    end

    private def validate_address!(address : String) : Nil
      unless Utils::Address.validate(address)
        raise ArgumentError.new("Invalid TRON address: #{address}")
      end
    end

    private def truthy_json?(v : JSON::Any?) : Bool
      return false if v.nil?
      return false if (b = v.as_bool?) && !b
      true
    end

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

    private def json_opt(v : JSON::Any?) : JSON::Any
      v.nil? ? JSON::Any.new(nil) : v
    end

    private def json_opt_float(v : Float64?) : JSON::Any
      v.nil? ? JSON::Any.new(nil) : JSON.parse(v.to_json)
    end
  end
end
