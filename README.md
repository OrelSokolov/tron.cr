# tron.cr

A Crystal port of [tron.rb](https://rubygems.org/gems/tron.rb) **1.2.4**
— the TRON blockchain toolkit: crypto core (secp256k1 signatures, TRON
addresses), TronGrid/Tronscan HTTP client services, Solidity ABI
encode/decode and transaction protobuf serialization. Oracle-verified:
**113 cases** recorded with the real tron.rb 1.2.4, replayed 1:1
(`crystal spec` green, 21 spec blocks).

## Installation

```yaml
dependencies:
  tron_cr:
    github: OrelSokolov/tron.cr
```

```sh
shards install
```

Requires **libsecp256k1** in the system — the port binds the same C
library the gem uses through rbsecp256k1, and signatures are
deterministic (RFC 6979), so oracle outputs match byte-for-byte.

## Usage

```crystal
key = Tron::Key.new(private_hex: "...")
key.address                    # => "T..." (keccak256 + 0x41 + base58check)
signature = key.sign("message")

client = Tron::Client.new
client.wallet_balance(address)
client.full_account_info(address)
client.get_wallet_portfolio(address)   # USD portfolio

Tron::Configuration.network = :mainnet
Tron::Utils::Address.validate("T...")
```

## Feature comparison vs tron.rb 1.2.4

### Crypto core

| Feature | Original (tron.rb) | Port (tron.cr) | Status |
|---|---|---|---|
| Key derivation: `private_hex` / `public_hex` (uncompressed) / `public_hex_compressed` | ✅ (rbsecp256k1) | Same libsecp256k1 via `@[Link("secp256k1")]` | ✅ |
| TRON address (`T...`, keccak256 + 0x41 + base58check) | ✅ | Same | ✅ |
| keccak256 (incl. empty string and unicode) | ✅ (keccak gem) | Same | ✅ |
| `sign` / `personal_sign` / `sign_typed_data` (TIP-191, v=27/28) | ✅ | Same, deterministic → byte-identical oracle | ✅ |

### Utils, configuration, cache

| Feature | Original | Port | Status |
|---|---|---|---|
| `Utils::Address`: validate/to_hex/from_hex/to_base58 | ✅ | Same | ✅ |
| `Utils::ChainId`, `Configuration` (three network URLs, cache TTL) | ✅ | Same | ✅ |
| Global `Tron::Cache` (fetch/TTL/stale fallback/stats), `Utils::Cache`, `Utils::RateLimiter` | ✅ | Same | ✅ |
| `Utils::HTTP` (cached GET, POST, API-key headers) | ✅ (Faraday/Net::HTTP) | Network calls behind a swappable transport (stub in specs, `HTTP::Client` in production); request dump of 20 HTTP calls built byte-for-byte like the gem | ✅ |

### Services & client

| Feature | Original | Port | Status |
|---|---|---|---|
| Balance (TRX/TRC20, mainnet-Tronscan and shasta-TronGrid paths) | ✅ | Same | ✅ |
| Resources (getaccountresource + getaccount fallback), Price (USD prices, formatting) | ✅ | Same | ✅ |
| Transaction (local txID SHA256 → secp256k1 signing, broadcast, wait_for_confirmation, `Error(string)` revert decoding) | ✅ | Same | ✅ |
| Contract (triggerconstantcontract / triggersmartcontract + payment helpers) | ✅ | Same | ✅ |
| `Client` (wallet balance / full account info / USD portfolio) | ✅ | Same | ✅ |

### ABI & protobuf

| Feature | Original | Port | Status |
|---|---|---|---|
| ABI Type parser (incl. tuple/arrays), Encoder/Decoder (dynamic types, arrays, tuples) | ✅ (google-protobuf + own ABI) | Same | ✅ |
| `encode_function_call` (keccak256 selector), Function/Event (method id, topic hash, decode_log), `solidity_packed` | ✅ | Same | ✅ |
| `TransactionRawSerializer` (raw_data → wire format for signing), `TransactionSerializer` | ✅ | Same | ✅ |

### Gem quirks reproduced 1:1 (oracle-confirmed)

The port deliberately reproduces tron.rb 1.2.4 bugs so byte-level
behavior matches:

- `Utils::HTTP.post` ignores passed headers — always sets Content-Type +
  TRON-PRO-API-KEY from the **global** config.
- Resources passes a JSON **string** to `post` → the body gets
  double-encoded (TronGrid tolerates it).
- `Services::Balance#cache_stats`/`#clear_cache` are declared after
  `private` → `Client#cache_stats` raises NoMethodError (the port raises
  the same message).
- `Abi::Encoder#hash` always fails for `hash256` ("Argument too long" —
  a bits-vs-bytes size check).
- `Function.from_abi`/`Event.from_abi` read a Symbol key from a
  String-keyed JSON hash → nil → signature without types (`balanceOf()`).
- `TransactionRawSerializer`: fee_limit (field 9) serialized before
  contract (7) and data (6); type_url without a length prefix.
- `coerce_number`: `"010"` → 8 (octal via `to_i(0)`), `"deadbeef"` → 0.
- `Client#get_wallet_portfolio` uses `10.0 **` (float) for TronGrid
  tokens without decimals.

## Deviations & Crystal-specific notes

- Recursive `Abi::Value` alias with case-based type filtering instead of
  `.as` casts; `Util.concat` for binary concatenation (`Array(Bytes)#join`
  produces a String); `as_i64?`/`as_f?` care around JSON::Any numeric
  conversions.

## Testing

```sh
crystal spec   # 21 spec blocks, 113 oracle cases
```

Oracle: `oracle/cases.rb` records the real tron.rb 1.2.4 into
`oracle/expected.yml` (crypto vectors, HTTP request dumps against a stub
transport, ABI round-trips, protobuf wire bytes); the Crystal specs
replay the same cases without edits.
