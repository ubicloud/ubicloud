# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresEmberRateLimit do
  it "counts attempts per address" do
    expect(described_class.record("198.51.100.7")).to eq(1)
    expect(described_class.record("198.51.100.7")).to eq(2)
    expect(described_class.record("198.51.100.8")).to eq(1)
  end

  it "starts a new window once the old one has run out" do
    described_class.record("198.51.100.7")
    described_class.record("198.51.100.7")
    described_class.where(ip: "198.51.100.7").update(window_start: Time.now - described_class::WINDOW - 60)
    expect(described_class.record("198.51.100.7")).to eq(1)
  end

  it "gives an attempt back" do
    2.times { described_class.record("198.51.100.7") }
    described_class.refund("198.51.100.7")
    expect(described_class[ip: "198.51.100.7"].count).to eq(1)
  end

  it "never refunds below zero" do
    described_class.record("198.51.100.7")
    2.times { described_class.refund("198.51.100.7") }
    expect(described_class[ip: "198.51.100.7"].count).to eq(0)
  end
end
