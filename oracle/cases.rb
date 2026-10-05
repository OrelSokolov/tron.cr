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
