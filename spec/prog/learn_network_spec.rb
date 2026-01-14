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
    let(:vm_host) { Prog::Vm::HostNexus.assemble("::1").subject }
    let(:ln) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }

    it "exits, saving the ip6 address" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return(ip6_interface_output)
      expect { ln.start }.to exit({"msg" => "learned network information"})
      vm_host.reload
      expect(vm_host.ip6.to_s).to eq("2a01:4f8:173:1ed3::2")
      expect(vm_host.net6.to_s).to eq("2a01:4f8:173:1ed3::/64")
    end

    it "pops if there is no global unique address prefix provided" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return("[]")
      expect { ln.start }.to exit({"msg" => "learned network information"})
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
      json = JSON.parse(<<~JSON)
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
      expect { lm.parse_ip_addr_j(json) }
        .to raise_error RuntimeError, "only one global unique address prefix supported on interface"
    end
  end
end
