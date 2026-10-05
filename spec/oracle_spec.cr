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
