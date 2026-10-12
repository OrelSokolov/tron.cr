#!/usr/bin/env ruby
# Oracle cases for tron.cr — порт tron.rb 1.2.4.
#
# Запуск против ОРИГИНАЛЬного гема (oracle-first, AGENTS.md):
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Все кейсы детерминированы: фиксированный приватный ключ; подписи
# детерминированы (libsecp256k1 — RFC 6979), поэтому порт, биндящий ту же
# C-библиотеку, обязан воспроизводить байты 1:1.

gem "tron.rb", "= 1.2.4"
require "tron.rb"
require "digest/keccak"
require "tron/utils/chain_id"

def case_run(id, value)
  puts "#{id}\t#{value}"
end

# Фиксированный тестовый ключ (никогда не используйте с реальными средствами)
PRIV_HEX = "8d2a5ae4b1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c"

key = Tron::Key.new(priv: PRIV_HEX)

# --- Ключ -------------------------------------------------------------------

case_run "private_hex", key.private_hex
case_run "public_hex", key.public_hex                 # несжатый, 04-префикс
case_run "public_hex_compressed", key.public_hex_compressed
case_run "address", key.address

# --- Keccak256 (оригинал: digest/keccak из гема keccak) ----------------------

["", "hello", "abc", "Тест 42"].each_with_index do |s, i|
  case_run "keccak_#{i}", Digest::Keccak.hexdigest(s, 256)
end

# --- Подпись (детерминированная, RFC 6979; вход — ровно 32 байт) ------------

blob = Digest::Keccak.digest("tron oracle blob", 256)
case_run "sign_hex", key.sign(blob)
case_run "personal_sign_hex", key.personal_sign("Hello, Tron!")
case_run "sign_typed_data_hex", key.sign_typed_data(Digest::Keccak.digest("typed payload", 256))

# --- Верификация -------------------------------------------------------------
# В tron.rb 1.2.4 публичного Key#verify нет (порт добавит ecdsa_verify
# через libsecp256k1 — кейсы появятся вместе с реализацией).

# personal_sign prefix (детерминированные байты префикса из Tron::Signature)
case_run "personal_prefix_hex", Tron::Signature.prefix_message("Hello, Tron!").unpack1("H*")

# =============================================================================
# Часть 2: Tron::Client (TronGrid/Tronscan HTTP), ABI, protobuf, utils.
# HTTP перехватывается на уровне Net::HTTP#request — оракул фиксирует
# реальные URL/headers/body, которые строит гем, и возвращает заготовленные
# ответы. Порт обязан воспроизвести и запросы, и разбор ответов.
# =============================================================================

require "net/http"
require "json"

ENV.delete("TRONGRID_API_KEY")
ENV.delete("TRONSCAN_API_KEY")

PRIV2 = "0000000000000000000000000000000000000000000000000000000000000001"
PRIV3 = "0000000000000000000000000000000000000000000000000000000000000002"
PRIV4 = "0000000000000000000000000000000000000000000000000000000000000003"

OWNER   = key.address                        # TYT3FFpHK86Xttcf2qTRP5QYeYft5gsLxN
EMPTY   = Tron::Key.new(priv: PRIV2).address
SHASTA  = Tron::Key.new(priv: PRIV3).address
ERRADDR = Tron::Key.new(priv: PRIV4).address

# --- HTTP-стаб --------------------------------------------------------------

module TronOracleStub
  REQUESTS = []
  RESPONSES = {}

  DROP_HEADERS = %w[accept-encoding user-agent].freeze
  # "accept" со значением "*/*" добавляет сам Net::HTTP на POST — шум клиента
  DROP_HEADERS_VALUE = { "accept" => "*/*" }.freeze

  def self.body_for(url, req)
    resp = RESPONSES[url]
    raise "Unstubbed URL: #{url}" if resp.nil?
    resp = resp.call(req) if resp.respond_to?(:call)
    raise "Unstubbed URL: #{url}" if resp.nil?
    resp.is_a?(String) ? resp : JSON.generate(resp)
  end

  # Нормализация значений для expected.yml: floats → %.10g (устойчивое
  # к различиям to_s между Ruby и Crystal), остальное — компактный JSON.
  def self.normalize(obj)
    case obj
    when Float then format("%.10g", obj)
    when Hash  then "{" + obj.map { |k, v| "#{JSON.generate(k.to_s)}:#{normalize(v)}" }.join(",") + "}"
    when Array then "[" + obj.map { |v| normalize(v) }.join(",") + "]"
    when nil   then "null"
    else JSON.generate(obj)
    end
  end

  def self.normalize_request(req)
    normalize({
      "method"  => req["method"],
      "url"     => req["url"],
      "body"    => req["body"],
      "headers" => req["headers"].reject { |k, v| DROP_HEADERS.include?(k) || DROP_HEADERS_VALUE[k] == v }
    })
  end
end

class Net::HTTP
  def request(req, *args)
    scheme = @use_ssl ? "https" : "http"
    url = "#{scheme}://#{address}#{(port == 443 || port == 80) ? "" : ":#{port}"}#{req.path}"
    recorded = {
      "method"  => req.method,
      "url"     => url,
      "body"    => req.body,
      "headers" => req.each_header.to_h
    }
    TronOracleStub::REQUESTS << recorded
    body = TronOracleStub.body_for(url, recorded)
    resp = Net::HTTPOK.new("1.1", "200", "OK")
    resp.instance_variable_set(:@body, body)
    resp.instance_variable_set(:@read, true)
    resp
  end
end

R = TronOracleStub::RESPONSES
OWNER_HEX   = Tron::Utils::Address.to_hex(OWNER)
EMPTY_HEX   = Tron::Utils::Address.to_hex(EMPTY)
SHASTA_HEX  = Tron::Utils::Address.to_hex(SHASTA)
ERRADDR_HEX = Tron::Utils::Address.to_hex(ERRADDR)

# TronGrid: аккаунт владельца (mainnet)
R["https://api.trongrid.io/v1/accounts/#{OWNER}"] = {
  "data" => [{ "balance" => 1_500_000_000 }]
}
# Пустой/неактивный аккаунт
R["https://api.trongrid.io/v1/accounts/#{EMPTY}"] = { "data" => [] }
# Аккаунт на Shasta (TRC20 через TronGrid)
R["https://api.shasta.trongrid.io/v1/accounts/#{SHASTA}"] = {
  "data" => [{
    "balance" => 1_500_000_000,
    "trc20" => [
      { "TKnF3Ugr8FFPMLZyvLBJR4Di2fEH42amw3" => 989_550_000_000 },
      { "TXbHqrEzanDPvww4vBwMwcRXYoWx3q6TRn" => 0 }
    ]
  }]
}
# Tronscan: TRC20-кошелёк (mainnet)
R["https://apilist.tronscanapi.com/api/account/wallet?address=#{OWNER}&asset_type=1"] = {
  "data" => [
    { "token_type" => 20, "token_abbr" => "USDT", "token_name" => "Tether USD",
      "balance" => "123.45", "token_decimal" => 6,
      "token_id" => "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" },
    { "token_type" => 20, "token_abbr" => "ZERO", "token_name" => "Zero Token",
      "balance" => "0", "token_decimal" => 2,
      "token_id" => "TXzZeroTokenPlaceholder0000000000000000001" },
    { "token_type" => 721, "token_abbr" => "NFT", "token_name" => "NFT Item",
      "balance" => "5", "token_decimal" => 0,
      "token_id" => "TXzNftPlaceholder000000000000000000000000x" }
  ]
}
R["https://apilist.tronscanapi.com/api/account/wallet?address=#{EMPTY}&asset_type=1"] = { "data" => [] }
# Цены
R["https://apilist.tronscanapi.com/api/token/price?token=trx"] = { "price_in_usd" => "0.2654" }
R["https://apilist.tronscanapi.com/api/token/price?token=usdt"] = { "price_in_usd" => "1.0" }
# Ресурсы: по адресу в теле запроса
R["https://api.trongrid.io/wallet/getaccountresource"] = lambda do |req|
  body = req["body"].to_s
  if body.include?(ERRADDR)
    { "Error" => "Account not found" }
  elsif body.include?(SHASTA)
    raise "oracle boom"
  else
    { "freeNetLimit" => 600, "freeNetUsed" => 100, "TotalNetLimit" => 43_200_000,
      "EnergyLimit" => 100_000, "EnergyUsed" => 25_000 }
  end
end
R["https://api.shasta.trongrid.io/wallet/getaccountresource"] = lambda do |req|
  raise "oracle boom" if req["body"].include?(SHASTA)
  { "freeNetLimit" => 1 }
end
R["https://api.shasta.trongrid.io/wallet/getaccount"] = {
  "data" => [{ "freeNetLimit" => 100, "freeNetUsed" => 10,
               "EnergyLimit" => 1000, "EnergyUsed" => 900,
               "StorageLimit" => 10, "StorageUsed" => 3 }]
}
R["https://api.trongrid.io/wallet/getaccount"] = {
  "data" => [{ "freeNetLimit" => 300, "freeNetUsed" => 50,
               "EnergyLimit" => 50_000, "EnergyUsed" => 10_000,
               "StorageLimit" => 100, "StorageUsed" => 40 }]
}
# Транзакции
TX_SUCCESS = "9c8a" * 16
TX_REVERT  = "7d11" * 16
R["https://api.trongrid.io/wallet/gettransactionbyid"] = lambda do |req|
  if req["body"].include?(TX_SUCCESS)
    { "txID" => TX_SUCCESS, "ret" => [{ "contractRet" => "SUCCESS" }] }
  else
    { "txID" => TX_REVERT, "ret" => [{ "contractRet" => "REVERT" }] }
  end
end
R["https://api.trongrid.io/wallet/gettransactioninfobyid"] = {
  "contractResult" => [
    "08c379a0" + "00" * 31 + "20" + "00" * 31 + "0f" +
    "5472616e73666572206661696c6564" + "00" * 17
  ]
}
R["https://api.trongrid.io/wallet/triggersmartcontract"] = {
  "result" => true,
  "transaction" => {
    "txID" => "ab" * 32,
    "raw_data" => {
      "contract" => [{
        "parameter" => {
          "value" => { "data" => "a9059cbb", "owner_address" => OWNER_HEX,
                       "contract_address" => SHASTA_HEX },
          "type_url" => "type.googleapis.com/protocol.TriggerSmartContract"
        },
        "type" => "TriggerSmartContract"
      }],
      "ref_block_bytes" => "0a2f", "ref_block_hash" => "cd" * 16,
      "expiration" => 1_700_000_000_000, "timestamp" => 1_699_999_000_000
    },
    "raw_data_hex" => "0a2f"
  }
}
R["https://api.trongrid.io/wallet/broadcasttransaction"] = { "result" => true, "txid" => TX_SUCCESS }
# Константные вызовы: селекторы считаем через keccak (как делает гем)
require "digest/keccak"
require "tron/utils/chain_id"
SEL_IS_PAY  = Digest::Keccak.hexdigest("isPaymentProcessed(address,bytes16)", 256)[0, 8]
SEL_FEE     = Digest::Keccak.hexdigest("getFeeDestination(address)", 256)[0, 8]
SEL_OPER    = Digest::Keccak.hexdigest("isOperatorRegistered(address)", 256)[0, 8]
OWNER_PAD   = "0" * 24 + OWNER_HEX[2, 40]
R["https://api.trongrid.io/wallet/triggerconstantcontract"] = lambda do |req|
  data = req["body"].to_s
  if data.include?(SEL_IS_PAY)
    { "result" => true, "constant_result" => ["00" * 31 + "01"] }
  elsif data.include?(SEL_FEE)
    { "result" => true, "constant_result" => ["0" * 24 + ERRADDR_HEX[2, 40]] }
  elsif data.include?(SEL_OPER)
    { "result" => true, "constant_result" => ["00" * 32] }
  else
    { "result" => false }
  end
end

# --- Глобальная конфигурация --------------------------------------------------

Tron.configure do |c|
  c.api_key = "test-key"
  c.tronscan_api_key = "scan-key"
end

NORM = TronOracleStub.method(:normalize)

# --- Utils::Address ------------------------------------------------------------

case_run "addr_validate_true",  Tron::Utils::Address.validate(OWNER)
case_run "addr_validate_false_len",     Tron::Utils::Address.validate("T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb")
case_run "addr_validate_false_prefix",  Tron::Utils::Address.validate("9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwbT" + "x" * 0)
case_run "addr_validate_false_checksum", Tron::Utils::Address.validate("TYT3FFpHK86Xttcf2qTRP5QYeYft5gsLxO")
case_run "addr_validate_false_empty",    Tron::Utils::Address.validate("")
case_run "addr_to_hex",     Tron::Utils::Address.to_hex(OWNER)
case_run "addr_from_hex",   Tron::Utils::Address.from_hex(OWNER_HEX)
case_run "addr_to_base58_raw20", Tron::Utils::Address.to_base58(OWNER_HEX[2, 40])
case_run "addr_to_hex_passthrough", Tron::Utils::Address.to_hex(OWNER_HEX)
case_run "addr_to_base58_passthrough", Tron::Utils::Address.to_base58(OWNER)

# --- ABI -------------------------------------------------------------------------

def abi_norm(v)
  case v
  when Integer then v.to_s
  when Float then format("%.10g", v)
  when Array then "[" + v.map { |x| abi_norm(x) }.join(",") + "]"
  when Hash then "{" + v.map { |k, x| "#{JSON.generate(k.to_s)}:#{abi_norm(x)}" }.join(",") + "}"
  when nil then "null"
  when String then JSON.generate(v)
  else JSON.generate(v.to_s)
  end
end

case_run "abi_split_params",
         Tron::Abi.split_function_params("uint256,(address,bytes32)[],bool,string").join("|")
case_run "abi_type_err_foo",   (Tron::Abi::Type.parse("foo") rescue $!.message)
case_run "abi_type_err_uint7", (Tron::Abi::Type.parse("uint7") rescue $!.message)
case_run "abi_type_err_addr8", (Tron::Abi::Type.parse("address8") rescue $!.message)
case_run "abi_type_to_s",      Tron::Abi::Type.parse("tuple(uint256,(string,bytes))[3][]").to_s

case_run "abi_encode_transfer",
         Tron::Abi.encode_function_call("transfer(address,uint256)", [OWNER, "1000000"])
case_run "abi_encode_noparams", Tron::Abi.encode_function_call("getBalance()", [])
case_run "abi_encode_bytes16",
         Tron::Abi.encode_function_call("isPaymentProcessed(address,bytes16)",
                                        [OWNER, "0123456789abcdef0123456789abcdef"])
case_run "abi_encode_mixed",
         Tron::Abi.encode(["uint256", "int128", "bool", "address", "bytes32"],
                          [2**256 - 1, -5, true, OWNER, "ab" * 32])
case_run "abi_encode_dynamic",
         Tron::Abi.encode(["string", "uint256[]", "bytes"], ["hello tron", [1, 2, 3], "0xdeadbeef"])
case_run "abi_encode_tuple",
         Tron::Abi.encode(["tuple(uint256,string)", "uint256"], [["42", "packed"], "7"])
case_run "abi_encode_ufixed", Tron::Abi.encode(["ufixed32x8"], [3.5])
case_run "abi_encode_coerce_hex",  Tron::Abi.encode(["uint256"], ["0x2a"])
case_run "abi_encode_coerce_oct",  Tron::Abi.encode(["uint256"], ["010"])
case_run "abi_encode_coerce_word", Tron::Abi.encode(["uint256"], ["deadbeef"])
case_run "abi_encode_addr_0x",     Tron::Abi.encode(["address"], ["0x" + OWNER_HEX[2, 40]])
case_run "abi_encode_hash",        (Tron::Abi.encode(["hash256"], ["cd" * 32]) rescue $!.message)

RT_TYPES  = ["uint256", "int128", "bool", "address", "string", "uint256[]"]
RT_VALUES = [2**256 - 1, -5, true, OWNER, "hello tron", [1, 2, 3]]
RT_HEX    = Tron::Abi.encode(RT_TYPES, RT_VALUES)
case_run "abi_decode_roundtrip", abi_norm(Tron::Abi.decode(RT_TYPES, RT_HEX))
case_run "abi_decode_output_bool", Tron::Abi.decode_output("bool", "0x" + "00" * 31 + "01")
case_run "abi_decode_bytes",
         Tron::Utils::Crypto.bin_to_hex(Tron::Abi.decode(["bytes"], Tron::Abi.encode(["bytes"], ["0xdeadbeef"])).first)
case_run "abi_decode_output_addr",
         Tron::Abi.decode_output("address", "0x" + "0" * 24 + OWNER_HEX[2, 40])

case_run "abi_packed",
         Tron::Abi.solidity_packed(
           ["uint128", "address", "bool", "string", "bytes4"],
           [777, OWNER, true, "raw", "0xaabbccdd"]
         ).unpack1("H*")

fn = Tron::Abi::Function.new(name: "transfer",
                             inputs: [{ type: "address" }, { type: "uint256" }])
case_run "abi_function_signature", fn.generate_signature
case_run "abi_function_method_id", fn.generate_method_id
case_run "abi_function_encode_input", fn.encode_input([OWNER, "1000000"])
case_run "abi_function_class_sig", Tron::Abi::Function.signature("transfer(address,uint256)")
case_run "abi_function_from_abi",
         Tron::Abi::Function.from_abi({
           "type" => "function", "name" => "balanceOf",
           "inputs" => [{ "type" => "address", "name" => "owner" }],
           "outputs" => [{ "type" => "uint256" }]
         }).generate_method_id
fn2 = Tron::Abi::Function.new(name: "balanceOf",
                              inputs: [{ type: "address" }],
                              outputs: [{ type: "uint256" }])
case_run "abi_function_decode_output", abi_norm(fn2.decode_output("0x" + format("%064x", 999)))

ev = Tron::Abi::Event.new(name: "Transfer",
                          inputs: [{ type: "address", name: "from", indexed: true },
                                   { type: "address", name: "to", indexed: true },
                                   { type: "uint256", name: "value", indexed: false }])
ev_topic = ev.generate_topic_hash
case_run "abi_event_topic", ev_topic
case_run "abi_event_class_sig", Tron::Abi::Event.signature("Transfer(address,address,uint256)")
case_run "abi_event_decode_log",
         abi_norm(ev.decode_log(
           ["0x" + ev_topic, "0x" + "0" * 24 + OWNER_HEX[2, 40], "0x" + "0" * 24 + SHASTA_HEX[2, 40]],
           "0x" + format("%064x", 1000)
         ))

# --- Protobuf ----------------------------------------------------------------------

pb_tx = {
  "raw_data" => {
    "ref_block_bytes" => "a1b2",
    "ref_block_num" => 12_345,
    "ref_block_hash" => "c0ffee00c0ffee00c0ffee00c0ffee00",
    "expiration" => 1_700_000_000_000,
    "timestamp" => 1_699_999_000_000,
    "fee_limit" => 100_000_000,
    "contract" => [{
      "type" => "TriggerSmartContract",
      "parameter" => {
        "value" => {
          "owner_address" => OWNER_HEX,
          "contract_address" => SHASTA_HEX,
          "data" => "a9059cbb0000",
          "call_value" => 0
        }
      }
    }]
  },
  "txID" => "ab" * 32
}
case_run "pb_serialize_trigger",
         Tron::Protobuf::TransactionRawSerializer.serialize(pb_tx).unpack1("H*")
case_run "pb_serializer_for_signing",
         Tron::Protobuf::TransactionSerializer.serialize_for_signing(pb_tx).unpack1("H*")
pb_tx2 = {
  "raw_data" => {
    "ref_block_bytes" => "a1b2",
    "contract" => [{
      "type" => "TransferContract",
      "parameter" => {
        "value" => { "owner_address" => OWNER_HEX, "to_address" => SHASTA_HEX, "amount" => 1_500_000 }
      }
    }]
  }
}
case_run "pb_serialize_transfer",
         Tron::Protobuf::TransactionRawSerializer.serialize(pb_tx2).unpack1("H*")

# --- Configuration / ChainId ---------------------------------------------------------

cfg = Tron::Configuration.new
case_run "cfg_urls_mainnet", "#{cfg.base_url}|#{cfg.tronscan_base_url}|#{cfg.cache_ttl}|#{cfg.cache_max_stale}|#{cfg.fee_limit}|#{cfg.timeout}|#{cfg.cache_enabled}"
cfg.network = :shasta
case_run "cfg_urls_shasta", "#{cfg.base_url}|#{cfg.tronscan_base_url}"
cfg.network = :nile
case_run "cfg_urls_nile", "#{cfg.base_url}|#{cfg.tronscan_base_url}"
case_run "chain_id_mainnet", Tron::Utils::ChainId.for_network(:mainnet)
case_run "chain_id_nile", Tron::Utils::ChainId.for_network(:nile)
case_run "chain_id_err", (Tron::Utils::ChainId.for_network(:shasta) rescue $!.message)

# --- Глобальный кеш -------------------------------------------------------------------

Tron::Cache.clear
Tron::Cache.reset_stats
case_run "cache_fetch_first", Tron::Cache.fetch("oracle-key", ttl: 300, max_stale: 600) { "v1" }
case_run "cache_fetch_hit",   Tron::Cache.fetch("oracle-key", ttl: 300, max_stale: 600) { "v2" }
case_run "cache_exists", Tron::Cache.exists?("oracle-key")
case_run "cache_global_stats", NORM.call(Tron::Cache.global_stats)
case_run "cache_delete_then_size", (Tron::Cache.delete("oracle-key"); Tron::Cache.size)

# --- Клиент и сервисы (заглушённый HTTP) ------------------------------------------------

client = Tron::Client.new(api_key: "test-key", tronscan_api_key: "scan-key")
shasta_client = Tron::Client.new(api_key: "test-key", network: :shasta)

case_run "client_get_wallet_balance", NORM.call(client.get_wallet_balance(OWNER))
case_run "client_cache_stats_err", (client.cache_stats rescue $!.message)
case_run "client_get_wallet_balance_again", NORM.call(client.get_wallet_balance(OWNER))
case_run "client_cache_stats_err_again", (client.cache_stats rescue $!.message)

case_run "balance_get_trx_empty",
         Tron::Client.new(api_key: "test-key").balance_service.get_trx(EMPTY)

case_run "client_get_trc20_shasta", NORM.call(shasta_client.balance_service.get_trc20_tokens(SHASTA))

case_run "resources_normal",
         NORM.call(client.resources_service.get(OWNER))
case_run "resources_error_default",
         NORM.call(client.resources_service.get(ERRADDR))
case_run "resources_fallback",
         NORM.call(shasta_client.resources_service.get(SHASTA))

case_run "price_usd_trx", format("%.10g", client.price_service.get_token_price_usd("trx"))
case_run "price_usd_usdt", format("%.10g", client.price_service.get_token_price_usd("usdt"))
case_run "price_token_raw", NORM.call(client.price_service.get_token_price("trx"))
case_run "price_value_usd", format("%.10g", client.price_service.get_token_value_usd("100", "trx"))
case_run "price_format_nil", client.price_service.format_price(nil)
case_run "price_format_tiny", client.price_service.format_price(0.00001)
case_run "price_format_frac", client.price_service.format_price(0.5)
case_run "price_format_big", client.price_service.format_price(123.45678)

case_run "client_get_full_account_info", NORM.call(client.get_full_account_info(OWNER))

portfolio_client = Tron::Client.new(api_key: "test-key", tronscan_api_key: "scan-key")
case_run "client_get_wallet_portfolio", NORM.call(portfolio_client.get_wallet_portfolio(OWNER))

# --- Сервис транзакций -------------------------------------------------------------------

tx_service = Tron::Services::Transaction.new(Tron.configuration)

begin
  $stdout = File.open(File::NULL, "w")
  success_val = tx_service.wait_for_transaction(TX_SUCCESS, 3)
  revert_err  = (tx_service.wait_for_transaction(TX_REVERT, 3) rescue $!.message)
ensure
  $stdout = STDOUT
end
case_run "tx_wait_success", NORM.call(success_val)
case_run "tx_wait_revert", revert_err

# --- Сервис контрактов ---------------------------------------------------------------------

contract_service = Tron::Services::Contract.new(Tron.configuration)

case_run "contract_call_payment_processed",
         contract_service.payment_processed?(SHASTA, OWNER, "0123456789abcdef0123456789abcdef")
case_run "contract_call_fee_destination",
         contract_service.get_fee_destination(SHASTA, OWNER)
case_run "contract_call_operator_registered",
         contract_service.operator_registered?(SHASTA, OWNER)
case_run "contract_trigger_flow",
         NORM.call(contract_service.trigger_contract(
                     contract_address: SHASTA,
                     function: "transfer(address,uint256)",
                     parameters: [OWNER, "1000000"],
                     private_key: PRIV_HEX,
                     fee_limit: 50_000_000,
                     call_value: 0
                   ))
case_run "contract_call_constant_hex",
         contract_service.call_contract(
           contract_address: SHASTA,
           function: "isOperatorRegistered(address)",
           parameters: [OWNER]
         )

# --- Дамп перехваченных запросов (порт обязан строить такие же) ------------------------------

TronOracleStub::REQUESTS.each_with_index do |req, i|
  case_run "req_#{i}", TronOracleStub.normalize_request(req)
end
