# Oracle spec: порт обязан воспроизвести oracle/expected.yml (снято с
# настоящего tron.rb 1.2.4 + rbsecp256k1/libsecp256k1). Подписи детерминиро-
# ваны (RFC 6979) и совпадают байт-в-байт, т.к. порт биндит ту же C-библиотеку.

require "spec"
require "../src/tron_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

def check(id, value)
  (EXPECTED[id]? || "MISSING #{id}").should eq value.to_s
end

PRIV_HEX = "8d2a5ae4b1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c"

describe "Tron oracle" do
  key = Tron::Key.new(PRIV_HEX)

  it "key" do
    check "private_hex", key.private_hex
    check "public_hex", key.public_hex
    check "public_hex_compressed", key.public_hex_compressed
    check "address", key.address
  end

  it "keccak256" do
    ["", "hello", "abc", "Тест 42"].each_with_index do |s, i|
      check "keccak_#{i}", Tron::Crypto.keccak256_hex(s)
    end
  end

  it "sign" do
    blob = Tron::Crypto.keccak256("tron oracle blob")
    check "sign_hex", key.sign(blob)
  end

  it "personal_sign" do
    check "personal_sign_hex", key.personal_sign("Hello, Tron!")
  end

  it "sign_typed_data" do
    check "sign_typed_data_hex", key.sign_typed_data(Tron::Crypto.keccak256("typed payload"))
  end

  it "personal prefix bytes" do
    check "personal_prefix_hex", Tron::Signature.prefix_message("Hello, Tron!").hexstring
  end

  it "verify (расширение порта: восстановление из подписи)" do
    blob = Tron::Crypto.keccak256("tron oracle blob")
    key.verify(blob, key.sign(blob)).should be_true
    # порча первого байта r-компоненты
    bad = key.sign(blob)
    flipped = bad[0] == '9' ? 'a' : '9'
    key.verify(blob, flipped + bad[1..]).should be_false
  end
end

# =============================================================================
# Часть 2: Client (TronGrid/Tronscan через заглушенный транспорт), ABI,
# protobuf, utils. Ожидания сняты с настоящего tron.rb 1.2.4 (oracle/cases.rb
# перехватывает Net::HTTP и пишет те же кейсы в oracle/expected.yml).
# =============================================================================

PRIV2 = "0000000000000000000000000000000000000000000000000000000000000001"
PRIV3 = "0000000000000000000000000000000000000000000000000000000000000002"
PRIV4 = "0000000000000000000000000000000000000000000000000000000000000003"

OWNER   = Tron::Key.new(PRIV_HEX).address
EMPTY   = Tron::Key.new(PRIV2).address
SHASTA  = Tron::Key.new(PRIV3).address
ERRADDR = Tron::Key.new(PRIV4).address

OWNER_HEX   = Tron::Utils::Address.to_hex(OWNER)
SHASTA_HEX  = Tron::Utils::Address.to_hex(SHASTA)
ERRADDR_HEX = Tron::Utils::Address.to_hex(ERRADDR)

TX_SUCCESS = "9c8a" * 16
TX_REVERT  = "7d11" * 16

# --- Нормализация значений (зеркало TronOracleStub.normalize/abi_norm в cases.rb)

def norm(a : JSON::Any) : String
  if i = a.as_i64? # целые идут как целые (as_f? в Crystal конвертит int → float)
    i.to_s
  elsif f = a.as_f?
    sprintf("%.10g", f)
  elsif h = a.as_h?
    "{" + h.map { |k, v| "#{k.to_json}:#{norm(v)}" }.join(",") + "}"
  elsif arr = a.as_a?
    "[" + arr.map { |v| norm(v) }.join(",") + "]"
  elsif a.nil?
    "null"
  else
    a.to_json
  end
end

def err_msg(&block : -> _) : String
  yield
  "NO ERROR"
rescue e : Exception
  e.message.to_s
end

def abi_norm(v : Tron::Abi::Value) : String
  case v
  when Nil                 then "null"
  when Bool                then v.to_s.to_json
  when Int32, Int64        then v.to_s
  when BigInt              then v.to_s
  when Float64             then sprintf("%.10g", v)
  when String              then v.to_json
  when Bytes               then Tron::Abi::Util.bin_to_hex(v)
  when Array(Tron::Abi::Value)
    "[" + v.map { |x| abi_norm(x) }.join(",") + "]"
  when Hash(String, Tron::Abi::Value)
    "{" + v.map { |k, x| "#{k.to_json}:#{abi_norm(x)}" }.join(",") + "}"
  else v.to_s.to_json
  end
end

# --- HTTP-стаб: порт шлёт запросы в Tron::Utils::HTTP.transport, сюда;

record StubReq, method : String, url : String, body : String?, headers : Hash(String, String)

module TronOracleStub
  REQUESTS = [] of StubReq
  RESPONSES = {} of String => (String | Proc(StubReq, String))

  def self.body_for(url : String, req : StubReq) : String
    resp = RESPONSES[url]?
    raise Exception.new("Unstubbed URL: #{url}") if resp.nil?
    resp = resp.call(req) if resp.is_a?(Proc(StubReq, String))
    resp.as(String)
  end

  def self.normalize_request(r : StubReq) : String
    headers = JSON::Any.new({} of String => JSON::Any)
    r.headers.each do |k, v|
      dk = k.downcase # Net::HTTP хранит заголовки в lower-case
      next if dk.in?("accept-encoding", "user-agent")
      next if dk == "accept" && v == "*/*"
      headers.as_h[dk] = JSON::Any.new(v)
    end
    norm(JSON::Any.new({
      "method"  => JSON::Any.new(r.method),
      "url"     => JSON::Any.new(r.url),
      "body"    => r.body.nil? ? JSON::Any.new(nil) : JSON::Any.new(r.body.not_nil!),
      "headers" => headers,
    } of String => JSON::Any))
  end
end

Tron::Utils::HTTP.transport = ->(req : Tron::Utils::HTTP::Request) do
  stub_req = StubReq.new(req.method, req.url, req.body, req.headers.dup)
  TronOracleStub::REQUESTS << stub_req
  TronOracleStub.body_for(req.url, stub_req)
end

R = TronOracleStub::RESPONSES

# Заготовленные ответы (зеркало oracle/cases.rb)
R["https://api.trongrid.io/v1/accounts/#{OWNER}"] =
  %({"data":[{"balance":1500000000}]})
R["https://api.trongrid.io/v1/accounts/#{EMPTY}"] =
  %({"data":[]})
R["https://api.shasta.trongrid.io/v1/accounts/#{SHASTA}"] =
  %({"data":[{"balance":1500000000,"trc20":[{"TKnF3Ugr8FFPMLZyvLBJR4Di2fEH42amw3":989550000000},{"TXbHqrEzanDPvww4vBwMwcRXYoWx3q6TRn":0}]}]})
R["https://apilist.tronscanapi.com/api/account/wallet?address=#{OWNER}&asset_type=1"] =
  %({"data":[{"token_type":20,"token_abbr":"USDT","token_name":"Tether USD","balance":"123.45","token_decimal":6,"token_id":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"},{"token_type":20,"token_abbr":"ZERO","token_name":"Zero Token","balance":"0","token_decimal":2,"token_id":"TXzZeroTokenPlaceholder0000000000000000001"},{"token_type":721,"token_abbr":"NFT","token_name":"NFT Item","balance":"5","token_decimal":0,"token_id":"TXzNftPlaceholder000000000000000000000000x"}]})
R["https://apilist.tronscanapi.com/api/account/wallet?address=#{EMPTY}&asset_type=1"] =
  %({"data":[]})
R["https://apilist.tronscanapi.com/api/token/price?token=trx"] =
  %({"price_in_usd":"0.2654"})
R["https://apilist.tronscanapi.com/api/token/price?token=usdt"] =
  %({"price_in_usd":"1.0"})
R["https://api.trongrid.io/wallet/getaccountresource"] = ->(req : StubReq) do
  body = req.body.to_s
  if body.includes?(ERRADDR)
    %({"Error":"Account not found"})
  elsif body.includes?(SHASTA)
    raise Exception.new("oracle boom")
  else
    %({"freeNetLimit":600,"freeNetUsed":100,"TotalNetLimit":43200000,"EnergyLimit":100000,"EnergyUsed":25000})
  end
end
R["https://api.trongrid.io/wallet/getaccount"] =
  %({"data":[{"freeNetLimit":300,"freeNetUsed":50,"EnergyLimit":50000,"EnergyUsed":10000,"StorageLimit":100,"StorageUsed":40}]})
R["https://api.shasta.trongrid.io/wallet/getaccountresource"] = ->(req : StubReq) do
  raise Exception.new("oracle boom") if req.body.to_s.includes?(SHASTA)
  %({"freeNetLimit":1})
end
R["https://api.shasta.trongrid.io/wallet/getaccount"] =
  %({"data":[{"freeNetLimit":100,"freeNetUsed":10,"EnergyLimit":1000,"EnergyUsed":900,"StorageLimit":10,"StorageUsed":3}]})
R["https://api.trongrid.io/wallet/gettransactionbyid"] = ->(req : StubReq) do
  if req.body.to_s.includes?(TX_SUCCESS)
    %({"txID":"#{TX_SUCCESS}","ret":[{"contractRet":"SUCCESS"}]})
  else
    %({"txID":"#{TX_REVERT}","ret":[{"contractRet":"REVERT"}]})
  end
end
R["https://api.trongrid.io/wallet/gettransactioninfobyid"] =
  %({"contractResult":["08c379a0#{"00" * 31}20#{"00" * 31}0f5472616e73666572206661696c6564#{"00" * 17}"]})
R["https://api.trongrid.io/wallet/triggersmartcontract"] =
  %({"result":true,"transaction":{"txID":"#{"ab" * 32}","raw_data":{"contract":[{"parameter":{"value":{"data":"a9059cbb","owner_address":"#{OWNER_HEX}","contract_address":"#{SHASTA_HEX}"},"type_url":"type.googleapis.com/protocol.TriggerSmartContract"},"type":"TriggerSmartContract"}],"ref_block_bytes":"0a2f","ref_block_hash":"#{"cd" * 16}","expiration":1700000000000,"timestamp":1699999000000},"raw_data_hex":"0a2f"}})
R["https://api.trongrid.io/wallet/broadcasttransaction"] =
  %({"result":true,"txid":"#{TX_SUCCESS}"})

SEL_IS_PAY = Tron::Crypto.keccak256_hex("isPaymentProcessed(address,bytes16)")[0, 8]
SEL_FEE    = Tron::Crypto.keccak256_hex("getFeeDestination(address)")[0, 8]
SEL_OPER   = Tron::Crypto.keccak256_hex("isOperatorRegistered(address)")[0, 8]
R["https://api.trongrid.io/wallet/triggerconstantcontract"] = ->(req : StubReq) do
  data = req.body.to_s
  if data.includes?(SEL_IS_PAY)
    %({"result":true,"constant_result":["#{"00" * 31}01"]})
  elsif data.includes?(SEL_FEE)
    %({"result":true,"constant_result":["#{"0" * 24}#{ERRADDR_HEX[2, 40]}"]})
  elsif data.includes?(SEL_OPER)
    %({"result":true,"constant_result":["#{"00" * 32}"]})
  else
    %({"result":false})
  end
end

# Глобальная конфигурация (как Tron.configure в cases.rb)
Tron.configure do |c|
  c.api_key = "test-key"
  c.tronscan_api_key = "scan-key"
end

describe "Tron oracle part 2" do
  it "utils address" do
    check "addr_validate_true", Tron::Utils::Address.validate(OWNER)
    check "addr_validate_false_len", Tron::Utils::Address.validate("T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb")
    check "addr_validate_false_prefix", Tron::Utils::Address.validate("9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwbT")
    check "addr_validate_false_checksum", Tron::Utils::Address.validate(OWNER[0, 33] + (OWNER[33]? == 'O' ? 'x' : 'O'))
    check "addr_validate_false_empty", Tron::Utils::Address.validate("")
    check "addr_to_hex", Tron::Utils::Address.to_hex(OWNER)
    check "addr_from_hex", Tron::Utils::Address.from_hex(OWNER_HEX)
    check "addr_to_base58_raw20", Tron::Utils::Address.to_base58(OWNER_HEX[2, 40])
    check "addr_to_hex_passthrough", Tron::Utils::Address.to_hex(OWNER_HEX)
    check "addr_to_base58_passthrough", Tron::Utils::Address.to_base58(OWNER)
  end

  it "abi types" do
    check "abi_split_params",
      Tron::Abi.split_function_params("uint256,(address,bytes32)[],bool,string").join("|")
    check "abi_type_err_foo", err_msg { Tron::Abi::Type.parse("foo") }
    check "abi_type_err_uint7", err_msg { Tron::Abi::Type.parse("uint7") }
    check "abi_type_err_addr8", err_msg { Tron::Abi::Type.parse("address8") }
    check "abi_type_to_s", Tron::Abi::Type.parse("tuple(uint256,(string,bytes))[3][]").to_s
  end

  it "abi encode" do
    check "abi_encode_transfer",
      Tron::Abi.encode_function_call("transfer(address,uint256)", [OWNER, "1000000"] of Tron::Abi::Value)
    check "abi_encode_noparams", Tron::Abi.encode_function_call("getBalance()", [] of Tron::Abi::Value)
    check "abi_encode_bytes16",
      Tron::Abi.encode_function_call("isPaymentProcessed(address,bytes16)",
        [OWNER, "0123456789abcdef0123456789abcdef"] of Tron::Abi::Value)
    check "abi_encode_mixed",
      Tron::Abi.encode(["uint256", "int128", "bool", "address", "bytes32"],
        [BigInt.new(2) ** 256 - 1, -5, true, OWNER, "ab" * 32] of Tron::Abi::Value)
    check "abi_encode_dynamic",
      Tron::Abi.encode(["string", "uint256[]", "bytes"],
        ["hello tron", [1, 2, 3] of Tron::Abi::Value, "0xdeadbeef"] of Tron::Abi::Value)
    check "abi_encode_tuple",
      Tron::Abi.encode(["tuple(uint256,string)", "uint256"],
        [["42", "packed"] of Tron::Abi::Value, "7"] of Tron::Abi::Value)
    check "abi_encode_ufixed", Tron::Abi.encode(["ufixed32x8"], [3.5] of Tron::Abi::Value)
    check "abi_encode_coerce_hex", Tron::Abi.encode(["uint256"], ["0x2a"] of Tron::Abi::Value)
    check "abi_encode_coerce_oct", Tron::Abi.encode(["uint256"], ["010"] of Tron::Abi::Value)
    check "abi_encode_coerce_word", Tron::Abi.encode(["uint256"], ["deadbeef"] of Tron::Abi::Value)
    check "abi_encode_addr_0x", Tron::Abi.encode(["address"], ["0x" + OWNER_HEX[2, 40]] of Tron::Abi::Value)
    check "abi_encode_hash", err_msg { Tron::Abi.encode(["hash256"], ["cd" * 32] of Tron::Abi::Value) }
  end

  it "abi decode" do
    rt_types = ["uint256", "int128", "bool", "address", "string", "uint256[]"]
    rt_values = [BigInt.new(2) ** 256 - 1, -5, true, OWNER, "hello tron",
                 [1, 2, 3] of Tron::Abi::Value] of Tron::Abi::Value
    rt_hex = Tron::Abi.encode(rt_types, rt_values)
    check "abi_decode_roundtrip", abi_norm(Tron::Abi.decode(rt_types, rt_hex))
    check "abi_decode_output_bool", Tron::Abi.decode_output("bool", "0x" + "00" * 31 + "01")
    decoded_bytes = Tron::Abi.decode(["bytes"], Tron::Abi.encode(["bytes"], ["0xdeadbeef"] of Tron::Abi::Value)).first
    check "abi_decode_bytes",
      Tron::Abi::Util.bin_to_hex(decoded_bytes.as(Bytes))
    check "abi_decode_output_addr",
      Tron::Abi.decode_output("address", "0x" + "0" * 24 + OWNER_HEX[2, 40])
  end

  it "abi packed" do
    check "abi_packed",
      Tron::Abi.solidity_packed(
        ["uint128", "address", "bool", "string", "bytes4"],
        [777, OWNER, true, "raw", "0xaabbccdd"] of Tron::Abi::Value
      ).hexstring
  end

  it "abi function" do
    fn = Tron::Abi::Function.new(
      name: "transfer",
      inputs: [Tron::Abi::Function::Param.new("address"), Tron::Abi::Function::Param.new("uint256")])
    check "abi_function_signature", fn.generate_signature
    check "abi_function_method_id", fn.generate_method_id
    check "abi_function_encode_input", fn.encode_input([OWNER, "1000000"] of Tron::Abi::Value)
    check "abi_function_class_sig", Tron::Abi::Function.signature("transfer(address,uint256)")
    check "abi_function_from_abi",
      Tron::Abi::Function.from_abi(JSON.parse(
        %({"type":"function","name":"balanceOf","inputs":[{"type":"address","name":"owner"}],"outputs":[{"type":"uint256"}]})
      )).generate_method_id
    fn2 = Tron::Abi::Function.new(
      name: "balanceOf",
      inputs: [Tron::Abi::Function::Param.new("address")] of Tron::Abi::Function::Param,
      outputs: [Tron::Abi::Function::Param.new("uint256")] of Tron::Abi::Function::Param)
    check "abi_function_decode_output", abi_norm(fn2.decode_output("0x" + sprintf("%064x", 999)))
  end

  it "abi event" do
    ev = Tron::Abi::Event.new(
      name: "Transfer",
      inputs: [
        Tron::Abi::Event::Param.new("address", "from", true),
        Tron::Abi::Event::Param.new("address", "to", true),
        Tron::Abi::Event::Param.new("uint256", "value", false),
      ])
    ev_topic = ev.generate_topic_hash
    check "abi_event_topic", ev_topic
    check "abi_event_class_sig", Tron::Abi::Event.signature("Transfer(address,address,uint256)")
    check "abi_event_decode_log", abi_norm(ev.decode_log(
      ["0x" + ev_topic, "0x" + "0" * 24 + OWNER_HEX[2, 40], "0x" + "0" * 24 + SHASTA_HEX[2, 40]],
      "0x" + sprintf("%064x", 1000)
    ))
  end

  it "protobuf" do
    pb_tx = JSON.parse(%({"raw_data":{"ref_block_bytes":"a1b2","ref_block_num":12345,"ref_block_hash":"c0ffee00c0ffee00c0ffee00c0ffee00","expiration":1700000000000,"timestamp":1699999000000,"fee_limit":100000000,"contract":[{"type":"TriggerSmartContract","parameter":{"value":{"owner_address":"#{OWNER_HEX}","contract_address":"#{SHASTA_HEX}","data":"a9059cbb0000","call_value":0}}}]},"txID":"#{"ab" * 32}"}))
    check "pb_serialize_trigger", Tron::Protobuf::TransactionRawSerializer.serialize(pb_tx).hexstring
    check "pb_serializer_for_signing", Tron::Protobuf::TransactionSerializer.serialize_for_signing(pb_tx).hexstring
    pb_tx2 = JSON.parse(%({"raw_data":{"ref_block_bytes":"a1b2","contract":[{"type":"TransferContract","parameter":{"value":{"owner_address":"#{OWNER_HEX}","to_address":"#{SHASTA_HEX}","amount":1500000}}}]}}))
    check "pb_serialize_transfer", Tron::Protobuf::TransactionRawSerializer.serialize(pb_tx2).hexstring
  end

  it "configuration / chain_id" do
    cfg = Tron::Configuration.new
    check "cfg_urls_mainnet", "#{cfg.base_url}|#{cfg.tronscan_base_url}|#{cfg.cache_ttl}|#{cfg.cache_max_stale}|#{cfg.fee_limit}|#{cfg.timeout}|#{cfg.cache_enabled}"
    cfg.network = "shasta"
    check "cfg_urls_shasta", "#{cfg.base_url}|#{cfg.tronscan_base_url}"
    cfg.network = "nile"
    check "cfg_urls_nile", "#{cfg.base_url}|#{cfg.tronscan_base_url}"
    check "chain_id_mainnet", Tron::Utils::ChainId.for_network("mainnet")
    check "chain_id_nile", Tron::Utils::ChainId.for_network("nile")
    check "chain_id_err", err_msg { Tron::Utils::ChainId.for_network("shasta") }
  end

  it "global cache" do
    Tron::Cache.clear
    Tron::Cache.reset_stats
    check "cache_fetch_first", Tron::Cache.fetch("oracle-key", 300.0, 600.0) { JSON::Any.new("v1") }.as_s
    check "cache_fetch_hit", Tron::Cache.fetch("oracle-key", 300.0, 600.0) { JSON::Any.new("v2") }.as_s
    check "cache_exists", Tron::Cache.exists?("oracle-key")
    check "cache_global_stats", norm(Tron::Cache.global_stats)
    Tron::Cache.delete("oracle-key")
    check "cache_delete_then_size", Tron::Cache.size
  end

  it "client balance" do
    client = Tron::Client.new(api_key: "test-key", tronscan_api_key: "scan-key")
    shasta_client = Tron::Client.new(api_key: "test-key", network: "shasta")

    check "client_get_wallet_balance", norm(client.get_wallet_balance(OWNER))
    check "client_cache_stats_err", err_msg { client.cache_stats }
    check "client_get_wallet_balance_again", norm(client.get_wallet_balance(OWNER))
    check "client_cache_stats_err_again", err_msg { client.cache_stats }

    check "balance_get_trx_empty",
      Tron::Client.new(api_key: "test-key").balance_service.get_trx(EMPTY)

    check "client_get_trc20_shasta", norm(shasta_client.balance_service.get_trc20_tokens(SHASTA))

    check "resources_normal", norm(client.resources_service.get(OWNER))
    check "resources_error_default", norm(client.resources_service.get(ERRADDR))
    check "resources_fallback", norm(shasta_client.resources_service.get(SHASTA))

    check "price_usd_trx", sprintf("%.10g", client.price_service.get_token_price_usd("trx").not_nil!)
    check "price_usd_usdt", sprintf("%.10g", client.price_service.get_token_price_usd("usdt").not_nil!)
    check "price_token_raw", norm(client.price_service.get_token_price("trx").not_nil!)
    check "price_value_usd", sprintf("%.10g", client.price_service.get_token_value_usd("100", "trx").not_nil!)
    check "price_format_nil", client.price_service.format_price(nil)
    check "price_format_tiny", client.price_service.format_price(0.00001)
    check "price_format_frac", client.price_service.format_price(0.5)
    check "price_format_big", client.price_service.format_price(123.45678)

    check "client_get_full_account_info", norm(client.get_full_account_info(OWNER))

    portfolio_client = Tron::Client.new(api_key: "test-key", tronscan_api_key: "scan-key")
    check "client_get_wallet_portfolio", norm(portfolio_client.get_wallet_portfolio(OWNER))
  end

  it "transaction service" do
    tx_service = Tron::Services::Transaction.new(Tron.configuration)

    success_val = tx_service.wait_for_transaction(TX_SUCCESS, 3)
    revert_err = begin
      tx_service.wait_for_transaction(TX_REVERT, 3)
      "NO ERROR"
    rescue e : Exception
      e.message.to_s
    end
    check "tx_wait_success", norm(success_val)
    check "tx_wait_revert", revert_err
  end

  it "contract service" do
    contract_service = Tron::Services::Contract.new(Tron.configuration)

    check "contract_call_payment_processed",
      contract_service.payment_processed?(SHASTA, OWNER, "0123456789abcdef0123456789abcdef")
    check "contract_call_fee_destination",
      contract_service.get_fee_destination(SHASTA, OWNER)
    check "contract_call_operator_registered",
      contract_service.operator_registered?(SHASTA, OWNER)
    check "contract_trigger_flow", norm(contract_service.trigger_contract(
      contract_address: SHASTA,
      function: "transfer(address,uint256)",
      parameters: [OWNER, "1000000"] of Tron::Abi::Value,
      private_key: PRIV_HEX,
      fee_limit: 50_000_000_i64,
      call_value: 0_i64
    ))
    check "contract_call_constant_hex", contract_service.call_contract(
      contract_address: SHASTA,
      function: "isOperatorRegistered(address)",
      parameters: [OWNER] of Tron::Abi::Value
    )
  end

  it "request dump (порт строит те же запросы, что и tron.rb)" do
    TronOracleStub::REQUESTS.each_with_index do |req, i|
      check "req_#{i}", TronOracleStub.normalize_request(req)
    end
  end
end
