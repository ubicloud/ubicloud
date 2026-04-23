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

    context "when provider is leaseweb" do
      let(:leaseweb_ips) {
        [
          Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26),
          Hosting::LeasewebApis::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/112", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 112),
          Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.176.0/29", source_host_ip: "23.105.171.112", is_failover: false, gateway: nil, mask: 29)
        ]
      }

      let(:leaseweb_vm_host) {
        expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips)
        Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91478").subject
      }

      let(:leaseweb_ln) { described_class.new(Strand.new(stack: [{"subject_id" => leaseweb_vm_host.id}])) }

      it "hops to setup_leaseweb_networking for leaseweb hosts" do
        expect { leaseweb_ln.start }.to hop("setup_leaseweb_networking")
      end
    end
  end

  describe "#setup_leaseweb_networking" do
    let(:leaseweb_ips) {
      [
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/112", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 112),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.176.0/29", source_host_ip: "23.105.171.112", is_failover: false, gateway: nil, mask: 29)
      ]
    }

    let(:leaseweb_vm_host) {
      expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips)
      Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91478").subject
    }

    let(:leaseweb_ln) { described_class.new(Strand.new(stack: [{"subject_id" => leaseweb_vm_host.id}])) }

    it "sends subnet info to the host and hops to verify" do
      subnets = leaseweb_vm_host.assigned_subnets.map { |a| {cidr: a.cidr.to_s, gateway: a.gateway} }
      expected_json = subnets.to_json.shellescape

      expect(leaseweb_ln.sshable).to receive(:_cmd).with("sudo host/bin/setup-leaseweb-networking #{expected_json}").and_return("")
      expect { leaseweb_ln.setup_leaseweb_networking }.to hop("leaseweb_verify_networking")
    end
  end

  describe "#leaseweb_verify_networking" do
    let(:leaseweb_ips) {
      [
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26)
      ]
    }

    let(:leaseweb_vm_host) {
      expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips)
      Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91478").subject
    }

    let(:leaseweb_ln) { described_class.new(Strand.new(stack: [{"subject_id" => leaseweb_vm_host.id}])) }

    it "pings to verify connectivity and hops to learn ipv6" do
      expect(leaseweb_ln.sshable).to receive(:_cmd).with("ping -c 3 -w 10 8.8.8.8").and_return("")
      expect { leaseweb_ln.leaseweb_verify_networking }.to hop("leaseweb_learn_ipv6")
    end
  end

  describe "#leaseweb_learn_ipv6" do
    let(:leaseweb_ips) {
      [
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/112", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 112),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.176.0/29", source_host_ip: "23.105.171.112", is_failover: false, gateway: nil, mask: 29)
      ]
    }

    let(:leaseweb_vm_host) {
      expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips)
      Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91478").subject
    }

    let(:leaseweb_ln) { described_class.new(Strand.new(stack: [{"subject_id" => leaseweb_vm_host.id}])) }

    it "learns ipv6 from assigned subnets and pops" do
      expect { leaseweb_ln.leaseweb_learn_ipv6 }.to exit({"msg" => "learned network information"})
      leaseweb_vm_host.reload
      expect(leaseweb_vm_host.ip6.to_s).to eq("2607:f5b7:1:30:9::1")
      expect(leaseweb_vm_host.net6.to_s).to eq("2607:f5b7:1:30:9::/112")
    end

    it "picks the largest ipv6 subnet when multiple are assigned" do
      leaseweb_ips_multi_v6 = [
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/112", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 112),
        Hosting::LeasewebApis::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/64", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 64)
      ]
      expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips_multi_v6)
      vmh = Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91480").subject
      ln = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))

      expect { ln.leaseweb_learn_ipv6 }.to exit({"msg" => "learned network information"})
      vmh.reload
      expect(vmh.ip6.to_s).to eq("2607:f5b7:1:30::1")
      expect(vmh.net6.to_s).to eq("2607:f5b7:1:30::/64")
    end

    it "pops without setting ipv6 when no ipv6 subnet assigned" do
      leaseweb_ips_no_v6 = [
        Hosting::LeasewebApis::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26)
      ]
      expect(Hosting::Apis).to receive(:pull_ips).and_return(leaseweb_ips_no_v6)
      vmh = Prog::Vm::HostNexus.assemble("23.105.171.112", provider_name: HostProvider::LEASEWEB_PROVIDER_NAME, server_identifier: "91479").subject
      ln = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))

      expect { ln.leaseweb_learn_ipv6 }.to exit({"msg" => "learned network information"})
      vmh.reload
      expect(vmh.ip6).to be_nil
      expect(vmh.net6).to be_nil
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

    it "picks the largest prefix when multiple global unique address prefixes are provided" do
      json = JSON.parse(<<~JSON)
        [
          {
            "ifindex": 2,
            "addr_info": [
              {
                "local": "2a01:4f8:173:1ed3::2",
                "prefixlen": 112
              },
              {
                "local": "2a01:4f8:173:1ed3::",
                "prefixlen": 64
              }
            ]
          }
        ]
      JSON
      result = lm.parse_ip_addr_j(json)
      expect(result.addr).to eq("2a01:4f8:173:1ed3::")
      expect(result.prefixlen).to eq(64)
    end
  end
end
