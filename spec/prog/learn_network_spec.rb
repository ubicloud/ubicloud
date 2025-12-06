# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnNetwork do
  subject(:lm) { described_class.new(Strand.new(stack: [{}])) }

  let(:ip6_interface_output) do
    <<JSON
[
  {
    "ifindex": 2,
    "ifname": "enp0s31f6",
    "flags": [
      "BROADCAST",
      "MULTICAST",
      "UP",
      "LOWER_UP"
    ],
    "mtu": 1500,
    "operstate": "UP",
    "txqlen": 1000,
    "addr_info": [
      {
        "family": "inet6",
        "local": "2a01:4f8:173:1ed3::2",
        "prefixlen": 64,
        "scope": "global",
        "valid_life_time": 4294967295,
        "preferred_life_time": 4294967295
      },
      {}
    ]
  }
]
JSON
  end

  describe "#start" do
    it "exits, saving the ip6 address" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return(ip6_interface_output)
      vm_host = instance_double(VmHost)
      expect(vm_host).to receive(:update).with(ip6: "2a01:4f8:173:1ed3::2", net6: "2a01:4f8:173:1ed3::/64")
      expect(lm).to receive(:sshable).and_return(sshable)
      expect(lm).to receive(:vm_host).and_return(vm_host)
      expect { lm.start }.to exit({"msg" => "learned network information"})
    end
  end

  describe "#parse_ip_addr_j" do
    it "crashes if more than one interface provided" do
      expect {
        lm.parse_ip_addr_j(<<JSON)
[
  {
    "ifindex": 1
  },
  {
    "ifindex": 2
  }
]
JSON
      }.to raise_error RuntimeError, "only one interface supported"
    end

    it "crashes if more than one global unique address prefix is provided" do
      expect {
        lm.parse_ip_addr_j(<<JSON)
[
  {
    "ifindex": 2,
    "addr_info": [
      {
        "local": "2a01:4f8:173:1ed3::2",
        "prefixlen": 64
      },
      {
        "local": "2a01:4f8:173:1ed3::3",
        "prefixlen": 64
      }
    ]
  }
]
JSON
      }.to raise_error RuntimeError, "only one global unique address prefix supported on interface"
    end

    it "pops if there is no global unique address prefix provided" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return("[]")
      expect(lm).to receive(:sshable).and_return(sshable)
      expect { lm.start }.to exit({"msg" => "learned network information"})
    end
  end
end
