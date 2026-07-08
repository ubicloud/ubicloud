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
    it "returns nil when no interfaces are provided" do
      expect(lm.parse_ip_addr_j([])).to be_nil
    end

    it "picks the public prefix across multiple interfaces, ignoring ULA fabric links" do
      # Fabric/BGP-to-host setup: the routable /64 lives on lo while fabric1
      # and fabric2 carry ULA /127 point-to-point links.
      json = JSON.parse(<<~JSON)
        [
          {"ifindex": 1, "ifname": "lo", "addr_info": [
            {"family": "inet6", "local": "2607:f358:103:200::1", "prefixlen": 64, "scope": "global"},
            {"family": "inet6", "local": "fdfa:b32c:6d05:b6e2::1", "prefixlen": 128, "scope": "global"},
            {}
          ]},
          {"ifindex": 3, "ifname": "fabric1", "addr_info": [
            {"family": "inet6", "local": "fdfa:b32c:6d05:ffff::c", "prefixlen": 127, "scope": "global"},
            {}
          ]},
          {"ifindex": 4, "ifname": "fabric2", "addr_info": [
            {"family": "inet6", "local": "fdfa:b32c:6d05:ffff::e", "prefixlen": 127, "scope": "global"},
            {}
          ]}
        ]
      JSON
      expect(lm.parse_ip_addr_j(json)).to eq(described_class::Ip6.new("2607:f358:103:200::1", 64))
    end

    it "prefers the largest network when multiple public prefixes are present" do
      json = JSON.parse(<<~JSON)
        [
          {"addr_info": [
            {"local": "2607:f5b7:1:64:1::", "prefixlen": 112},
            {"local": "2a01:4f8:173:1ed3::2", "prefixlen": 64}
          ]}
        ]
      JSON
      expect(lm.parse_ip_addr_j(json)).to eq(described_class::Ip6.new("2a01:4f8:173:1ed3::2", 64))
    end

    it "returns nil when only ULA addresses are present, even at a short prefix length" do
      json = JSON.parse(<<~JSON)
        [
          {"addr_info": [{"local": "fd00:1234::1", "prefixlen": 64}]}
        ]
      JSON
      expect(lm.parse_ip_addr_j(json)).to be_nil
    end

    it "crashes when more than one public prefix shares the largest network" do
      json = JSON.parse(<<~JSON)
        [
          {"addr_info": [
            {"local": "2a01:4f8:173:1ed3::2", "prefixlen": 64},
            {"local": "2a01:4f8:173:1ed3::3", "prefixlen": 64}
          ]}
        ]
      JSON
      expect { lm.parse_ip_addr_j(json) }
        .to raise_error RuntimeError, "found more than one global unique address prefix"
    end
  end
end
