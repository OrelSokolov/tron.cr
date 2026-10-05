# tron.cr — порт tron.rb

> ⚠️ Крипто-ядро готово и oracle-верифицировано; HTTP-клиент (TronGrid) — TODO.

Порт [tron.rb](https://rubygems.org/gems/tron.rb) **1.2.4** на Crystal.
Оригинал: `~/.rvm/gems/ruby-3.4.5/gems/tron.rb-1.2.4`.

## ПРОВЕРЕНО: связь с C-библиотекой

tron.rb → **rbsecp256k1** (биндинг **libsecp256k1**) — используется в
`lib/tron/key.rb` (подпись/восстановление). Прочие зависимости чистые:
`keccak`, `base58-alphabets`, `google-protobuf`, Faraday/Net::HTTP.

Порт биндит **ту же libsecp256k1** (`@[Link("secp256k1")]`), подписи
детерминированы (RFC 6979) → oracle-совпадение байт-в-байт.

## Статус

**Готово, зелёное**: 7 примеров (`crystal spec`), воспроизводят
`oracle/expected.yml` (снят с настоящего tron.rb 1.2.4, фиксированный
тестовый ключ):
- деривация ключа: `private_hex` / `public_hex` (uncompressed) /
  `public_hex_compressed`
- адрес TRON (`T...`, keccak256 + 0x41 + base58check)
- keccak256 (вкл. пустую строку и юникод)
- `sign` / `personal_sign` / `sign_typed_data` (TIP-191, v=27/28)
- байты префикса personal-message

## Реализовано

- `src/tron/crypto/keccak.cr` — чистый Crystal Keccak-256 (домен 0x01,
  НЕ sha3-256)
- `src/tron/crypto/base58.cr` — base58 (bitcoin-алфавит) + base58check
  (sha256², stdlib Digest)
- `src/tron/crypto/secp256k1.cr` — биндинг libsecp256k1: контексты,
  seckey_verify, pubkey create/serialize/parse, sign_recoverable,
  recover, ecdsa_verify (флаги сверены с `/usr/include/secp256k1.h`:
  CONTEXT_SIGN=0x201, EC_COMPRESSED=0x102, EC_UNCOMPRESSED=0x2)
- `src/tron/key.cr` — `Tron::Key` 1:1 (`private_hex/public_hex/address/
  sign/personal_sign/sign_typed_data`) + расширение `verify`
  (в tron.rb 1.2.4 публичного verify нет)
- `Tron::Signature.prefix_message` — TIP-191 personal-префикс

## TODO (по мере надобности сайта)

- `Tron::Client` — HTTP TronGrid (balance/transaction/contract/price/
  resources): порт `lib/tron/client.rb` + сервисов; на сайте уже
  изолировано адаптерами (`app/ports`, `app/adapters`)
- protobuf-энкодер `protocol/core.proto` (Transaction) — минимальный writer
- ABI-энкодер (`lib/tron/abi/*`) для смарт-контрактов
- `Tron::Configuration`, rate limiter, cache из tron.rb

## Заметки по Crystal

- fun-имена в lib обязаны быть полными (`secp256k1_context_create`)
- `out` — ключевое слово; RC-константы Keccak требуют суффикс `_u64`
- annotated-splat / union-alias restriction баги — см. PLAN jbuilder.cr
