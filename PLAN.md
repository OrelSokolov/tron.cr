# tron.cr — порт tron.rb

> ✅ Крипто-ядро + Tron::Client (TronGrid HTTP) + ABI + protobuf — готово,
> oracle-верифицировано (113 кейсов, `crystal spec` зелёный).

Порт [tron.rb](https://rubygems.org/gems/tron.rb) **1.2.4** на Crystal.
Оригинал: `~/.rvm/gems/ruby-3.4.5/gems/tron.rb-1.2.4`.

## ПРОВЕРЕНО: связь с C-библиотекой

tron.rb → **rbsecp256k1** (биндинг **libsecp256k1**) — используется в
`lib/tron/key.rb` (подпись/восстановление). Прочие зависимости чистые:
`keccak`, `base58-alphabets`, `google-protobuf`, Faraday/Net::HTTP.

Порт биндит **ту же libsecp256k1** (`@[Link("secp256k1")]`), подписи
детерминированы (RFC 6979) → oracle-совпадение байт-в-байт.

## Статус

**Готово, зелёное**: 21 spec-блок, 113 oracle-кейсов (`crystal spec`),
воспроизводят `oracle/expected.yml` (снято с настоящего tron.rb 1.2.4).

### Часть 1 — крипто-ядро (7 кейсов)

- деривация ключа: `private_hex` / `public_hex` (uncompressed) /
  `public_hex_compressed`
- адрес TRON (`T...`, keccak256 + 0x41 + base58check)
- keccak256 (вкл. пустую строку и юникод)
- `sign` / `personal_sign` / `sign_typed_data` (TIP-191, v=27/28)
- байты префикса personal-message

### Часть 2 — клиент, ABI, protobuf (106 кейсов)

- `Utils::Address`: validate/to_hex/from_hex/to_base58
- `Utils::ChainId`, `Configuration` (URL-ы трёх сетей, TTL кеша)
- глобальный `Tron::Cache` (fetch/TTL/stale-фолбэк/статистика)
- `Utils::Cache`, `Utils::RateLimiter`
- `Utils::HTTP` (GET c кешированием, POST, заголовки API-ключей) — сетевой
  вызов вынесен в подменяемый transport (в spec — заглушка, в бою — HTTP::Client)
- сервисы: Balance (TRX/TRC20, mainnet-Tronscan и shasta-TronGrid пути),
  Resources (getaccountresource + фолбэк на getaccount), Price (USD-цены,
  форматирование), Transaction (локальная подпись txID SHA256→secp256k1,
  броадкаст, wait_for_confirmation, декодирование Error(string)-revert),
  Contract (triggerconstantcontract / triggersmartcontract + payment helpers)
- `Client` (wallet balance / full account info / portfolio в USD)
- ABI: Type (парсер типов вкл. tuple/массивы), Encoder/Decoder (вкл.
  динамические типы, массивы, tuples), `encode`/`decode`,
  `encode_function_call` (селектор keccak256), Function/Event
  (method id, topic hash, decode_log), packed-энкодер (`solidity_packed`)
- protobuf: `TransactionRawSerializer` (raw_data транзакции → wire format
  для подписи), `TransactionSerializer`
- дамп из 20 HTTP-запросов (метод/URL/тело/заголовки): порт строит их
  байт-в-байт как tron.rb — включая квирки (см. ниже)

## Захваченные квирки tron.rb 1.2.4 (порт воспроизводит 1:1)

- `Utils::HTTP.post` игнорирует переданные заголовки: всегда ставит
  Content-Type + TRON-PRO-API-KEY из **глобальной** конфигурации
- Resources передаёт в `post` JSON-**строку** → тело запроса кодируется
  повторно (JSON-строка в кавычках) — TronGrid такое прощает
- `Services::Balance#cache_stats`/`#clear_cache` объявлены после `private` →
  `Client#cache_stats` падает с NoMethodError (порт бросает то же сообщение)
- `Abi::Encoder#hash`: `hash256` всегда падает («Argument too long» —
  size-проверка сравнивает биты с байтами)
- `Function.from_abi`/`Event.from_abi` читают `input[:type]` символьным
  ключом из строкового JSON-хеша → всегда nil → сигнатура без типов
  (`balanceOf()`), method id «не тот»
- `TransactionRawSerializer`: fee_limit (поле 9) сериализуется ДО contract
  (7) и data (6); type_url в parameter — без length-префикса
- `coerce_number`: десятичная строка парсится `to_i(0)` — `"010"` → 8
  (восьмеричная), `"deadbeef"` → 0
- `Client#get_wallet_portfolio` обращается с балансом TronGrid-токенов без
  decimals через `10.0 **` (float), а не целочисленно

## Заметки по Crystal

- fun-имена в lib обязаны быть полными (`secp256k1_context_create`)
- `out` — ключевое слово; RC-константы Keccak требуют суффикс `_u64`
- `String#starts_with?` — один аргумент; `Hash#key?` → `has_key?`
- рекурсивный alias `Abi::Value` + case-фильтрация типов вместо `.as`
- `Array(Bytes)#join` склеивает в String — для бинарной конкатенации
  `Util.concat`
- `JSON::Any#as_i?` — Int32 (переполнение на больших числах) → `as_i64?`;
  `as_f?` молча конвертит int → float
- `Int32 ** n` переполняется: для `2**high` в fixed/ufixed — `2.0_f64 ** n`
