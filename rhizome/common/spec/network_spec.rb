# frozen_string_literal: true

require_relative "../lib/network"

RSpec.describe "network" do
  describe "mac_to_ipv6_link_local" do
    it "converts a MAC address to an IPv6 link local address" do
      expect(mac_to_ipv6_link_local("3e:bd:a5:96:f7:b9")).to eq("fe80::3cbd:a5ff:fe96:f7b9")
    end

    it "sets the universal/local bit (bit 1) in the first octet" do
      # 00 -> 02, 02 -> 00
      expect(mac_to_ipv6_link_local("00:00:00:00:00:00")).to eq("fe80::0200:00ff:fe00:0000")
    end
  end

  describe "gen_mac" do
    it "generates a MAC address with the local bit set and multicast bit cleared" do
      100.times do
        mac = gen_mac
        expect(mac).to match(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
        first_byte = mac.split(":").first.to_i(16)
        expect(first_byte & 0x02).to eq(0x02), "local bit must be set, got: #{mac}"
        expect(first_byte & 0x01).to eq(0x00), "multicast bit must be cleared, got: #{mac}"
      end
    end
  end
end
