# frozen_string_literal: true

require "resolv"

RSpec.describe DnsChecker do
  it ".open returns DNS CNAME record lookup failures" do
    expect(described_class.open(["127.0.0.1"]) do
      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::CNAME)
        .and_return(Resolv::DNS::Resource::IN::CNAME.new("actual-val"))
      it.check(:CNAME, "rec", "expect-val")
    end).to eq [{actual_value: "actual-val", expected_value: "expect-val", record_name: "rec", type: :CNAME}]
  end

  it ".open returns DNS A record lookup failures" do
    expect(described_class.open(["127.0.0.1"]) do
      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::A)
        .and_return(Resolv::DNS::Resource::IN::A.new(Resolv::IPv4.new("\x0a\x00\x00\x01")))
      it.check(:A, "rec", "127.0.0.1")
    end).to eq [{actual_value: "10.0.0.1", expected_value: "127.0.0.1", record_name: "rec", type: :A}]
  end

  it ".open returns DNS AAAA record lookup failures" do
    expect(described_class.open(["127.0.0.1"]) do
      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::AAAA)
        .and_return(Resolv::DNS::Resource::IN::AAAA.new(Resolv::IPv6.new("\xfe\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02")))
      it.check(:AAAA, "rec", "fe80::1")
    end).to eq [{actual_value: "fe80::2", expected_value: "fe80::1", record_name: "rec", type: :AAAA}]
  end

  it ".open returns empty array if there are no failures" do
    expect(described_class.open(["127.0.0.1"]) do
      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::CNAME)
        .and_return(Resolv::DNS::Resource::IN::CNAME.new("expect-val"))
      it.check(:CNAME, "rec", "expect-val")

      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::A)
        .and_return(Resolv::DNS::Resource::IN::A.new(Resolv::IPv4.new("\x7f\x00\x00\x01")))
      it.check(:A, "rec", "127.0.0.1")

      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::AAAA)
        .and_return(Resolv::DNS::Resource::IN::AAAA.new(Resolv::IPv6.new("\xfe\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01")))
      it.check(:AAAA, "rec", "fe80::1")
    end).to eq []
  end

  it ".open returns exceptions as failures" do
    expect(described_class.open(["127.0.0.1"]) do
      expect(it.instance_variable_get(:@resolver)).to receive(:getresource).with("rec", Resolv::DNS::Resource::IN::CNAME)
        .and_raise(Resolv::ResolvError.new("foo"))
      it.check(:CNAME, "rec", "expect-val")
    end).to eq [{exception: "Resolv::ResolvError: foo", expected_value: "expect-val", record_name: "rec", type: :CNAME}]
  end
end
