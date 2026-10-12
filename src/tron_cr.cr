# tron_cr — порт tron.rb 1.2.4 на Crystal.

require "./tron/key"
require "./tron/utils/address"
require "./tron/utils/chain_id"
require "./tron/utils/cache"
require "./tron/utils/rate_limiter"
require "./tron/cache"
require "./tron/configuration"
require "./tron/utils/http"
require "./tron/abi"
require "./tron/protobuf"
require "./tron/services/balance"
require "./tron/services/resources"
require "./tron/services/price"
require "./tron/services/contract"
require "./tron/services/transaction"
require "./tron/client"
require "./tron/contract"

module Tron
  VERSION = "1.2.4.cr"

  # Дефолтный клиент (как Tron.client в tron.rb).
  def self.client : Client
    @@client ||= Client.new(
      api_key: Client.configuration.api_key,
      tronscan_api_key: Client.configuration.tronscan_api_key,
      network: Client.configuration.network,
      timeout: Client.configuration.timeout
    )
  end

  # Конфигурация дефолтного клиента (сбрасывает клиент при изменениях).
  def self.configure(&block : Configuration -> _) : Nil
    @@client = nil
    Client.configure do |config|
      yield config
    end
  end

  def self.configuration : Configuration
    Client.configuration
  end

  # Делегирование типовых методов дефолтному клиенту.
  def self.get_wallet_balance(address : String, strict : Bool = false) : JSON::Any
    client.get_wallet_balance(address, strict)
  end

  def self.get_full_account_info(address : String, strict : Bool = false) : JSON::Any
    client.get_full_account_info(address, strict)
  end

  def self.get_wallet_portfolio(address : String, include_zero_balances : Bool = false) : JSON::Any
    client.get_wallet_portfolio(address, include_zero_balances)
  end

  @@client : Client? = nil
end
