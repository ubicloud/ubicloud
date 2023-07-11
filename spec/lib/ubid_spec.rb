# frozen_string_literal: true

require_relative "../../lib/ubid"
require "ulid"

RSpec.describe UBID do
  it "can set_bits" do
    expect(described_class.set_bits(0, 0, 7, 0xab)).to eq(0xab)
    expect(described_class.set_bits(0xab, 8, 12, 0xc)).to eq(0xcab)
    expect(described_class.set_bits(0xcab, 40, 48, 0x12)).to eq(0x120000000cab)
  end

  it "can get bits" do
    expect(described_class.get_bits(0x120000000cab, 8, 11)).to eq(0xc)
  end

  it "can convert to base32" do
    tests = [
      ["0", 0], ["o", 0], ["A", 10], ["e", 14], ["m", 20], ["S", 25], ["z", 31]
    ]
    tests.each {
      expect(described_class.to_base32(_1[0])).to eq(_1[1])
    }
  end

  it "can extract bits as hex" do
    expect(described_class.extract_bits_as_hex(0x12345, 1, 3)).to eq("234")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 4, 5)).to eq("cdef0")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 1, 4)).to eq("0001")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 9, 5)).to eq("000ab")
  end

  it "can encode multiple numbers" do
    expect(described_class.from_base32_n(10 + 20 * 32 + 1 * 32 * 32, 3)).to eq("1ma")
  end

  it "fails to convert U to base32" do
    expect { described_class.to_base32("u") }.to raise_error RuntimeError, "Invalid base32 encoding: U"
  end

  it "can convert from base32" do
    tests = [
      [0, "0"], [12, "c"], [16, "g"], [20, "m"], [26, "t"], [28, "w"], [31, "z"]
    ]
    tests.each {
      expect(described_class.from_base32(_1[0])).to eq(_1[1])
    }
  end

  it "can convert multiple from base32" do
    expect(described_class.to_base32_n("1MA")).to eq(10 + 20 * 32 + 1 * 32 * 32)
  end

  it "fails to convert from out of range numbers" do
    expect {
      described_class.from_base32(-1)
    }.to raise_error RuntimeError, "Invalid base32 number: -1"

    expect {
      described_class.from_base32(32)
    }.to raise_error RuntimeError, "Invalid base32 number: 32"
  end

  it "can calculate parity" do
    expect(described_class.parity(0b10101)).to eq(1)
    expect(described_class.parity(0b101011)).to eq(0)
  end

  it "can create from parts & encode it & parse it" do
    id = described_class.from_parts(1000, "ab", 3, 12292929)
    expect(described_class.parse(id.to_s).to_i).to eq(id.to_i)
  end

  it "generates the same ULID as the ULID it was generated from" do
    ulid1 = ULID.generate
    ubid1 = described_class.new(ulid1.to_i)
    ubid2 = described_class.parse(ubid1.to_s)
    ulid2 = ULID.from_integer(ubid2.to_i)
    expect(ulid1.to_s).to eq(ulid2.to_s)
  end

  it "can generate random ids" do
    ubid1 = described_class.generate("vm")
    ubid2 = described_class.parse(ubid1.to_s)
    expect(ubid2.to_i).to eq(ubid1.to_i)
  end

  it "can convert to and from uuid" do
    ubid1 = described_class.generate("sr")
    ubid2 = described_class.from_uuidish(ubid1.to_uuid)
    expect(ubid2.to_s).to eq(ubid1.to_s)
  end

  it "can convert from and to uuid" do
    uuid1 = "550e8400-e29b-41d4-a716-446655440000"
    uuid2 = described_class.from_uuidish(uuid1).to_uuid
    expect(uuid2).to eq(uuid1)
  end

  it "fails to parse if length is not 26" do
    expect {
      described_class.parse("123456")
    }.to raise_error RuntimeError, "Invalid encoding length: 6"
  end

  it "fails to parse if top bits parity is incorrect" do
    invalid_ubid = "vm164pbm96ba3grq6vbsvjb3ax"
    expect {
      described_class.parse(invalid_ubid)
    }.to raise_error RuntimeError, "Invalid top bits parity"
  end

  it "fails to parse if bottom bits parity is incorrect" do
    invalid_ubid = "vm064pbm96ba3grq6vbsvjb3az"
    expect {
      described_class.parse(invalid_ubid)
    }.to raise_error RuntimeError, "Invalid bottom bits parity"
  end
end
