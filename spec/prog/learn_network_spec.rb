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

    it "learns the ip6 address directly on a host that configures itself" do
      expect { ln.start }.to hop("learn_ip6")
    end
  end

  describe "#learn_ip6" do
    let(:vm_host) { Prog::Vm::HostNexus.assemble("::1").subject }
    let(:ln) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }

    it "exits, saving the ip6 address" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return(ip6_interface_output)
      expect { ln.learn_ip6 }.to exit({"msg" => "learned network information"})
      vm_host.reload
      expect(vm_host.ip6.to_s).to eq("2a01:4f8:173:1ed3::2")
      expect(vm_host.net6.to_s).to eq("2a01:4f8:173:1ed3::/64")
    end

    it "pops if there is no global unique address prefix provided" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j -6 addr show scope global").and_return("[]")
      expect { ln.learn_ip6 }.to exit({"msg" => "learned network information"})
    end
  end

  describe "leaseweb" do
    let(:vm_host) do
      vmh = create_vm_host
      vmh.sshable.update(host: "216.22.50.197")
      HostProvider.create do
        it.id = vmh.id
        it.server_identifier = "123"
        it.provider_name = HostProvider::LEASEWEB_PROVIDER_NAME
      end
      vmh
    end

    let(:ln) { described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}])) }

    let(:link_output) do
      JSON.generate([
        {ifindex: 2, ifname: "ens3f0np0", address: "8c:84:74:54:ea:d0"},
        {ifindex: 3, ifname: "ens3f1np1", address: "8c:84:74:54:ea:d1"},
      ])
    end

    let(:addr_output) do
      JSON.generate([{
        ifname: "ens3f0np0",
        addr_info: [
          {local: "216.22.50.197", prefixlen: 32},
          {local: "216.22.15.64", prefixlen: 26},
          {local: "2604:9a00:2100:a020:4::2", prefixlen: 112},
          {local: "2607:f5b7:3:104::1", prefixlen: 64},
        ],
      }])
    end

    # What the kernel holds in the beat between `netplan apply` returning and the
    # rest of the addresses landing.
    let(:unsettled_addr_output) do
      JSON.generate([{ifname: "ens3f0np0", addr_info: [{local: "216.22.50.197", prefixlen: 32}]}])
    end

    # The addresses and gateways setup hands verify through the frame: netplan
    # host offsets, not the /112 and /64 prefixes the API and Address rows carry.
    let(:expected_addresses) do
      ["216.22.50.197/32", "216.22.15.64/26", "2604:9a00:2100:a020:4::2/112", "2607:f5b7:3:104::1/64"]
    end
    let(:expected_gateways) { ["216.22.50.254", "2604:9a00:2100:a020::1"] }

    # Server 12493302 reports an internal MAC but no private network behind it,
    # and a null internal.ip.
    let(:private_networks) { [] }
    let(:internal_nic) { {mac: "8C:84:74:54:EA:D1"} }

    before do
      allow(Config).to receive_messages(
        leaseweb_connection_string: "https://api.leaseweb.com",
        leaseweb_api_key: "key123",
      )

      Excon.stub({path: "/bareMetals/v2/servers/123", method: :get},
        {status: 200, body: JSON.generate(networkInterfaces: {public: {mac: "8C:84:74:54:EA:D0"}, internal: internal_nic},
          isPrivateNetworkEnabled: private_networks.any?, privateNetworks: private_networks)})

      block = (64..127).map do
        {ip: "216.22.15.#{it}/26", prefixLength: 26, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: ""}
      end
      rows = [
        *block,
        {ip: "216.22.50.197/26", prefixLength: 26, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: true, gateway: "216.22.50.254"},
        {ip: "2604:9a00:2100:a020:4::_112/64", prefixLength: 64, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: "2604:9a00:2100:a020::1"},
        {ip: "2607:f5b7:3:104::_64/64", prefixLength: 64, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: ""},
      ]
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(ips: rows.take(50), _metadata: {totalCount: rows.length})})
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 50}},
        {status: 200, body: JSON.generate(ips: rows.drop(50), _metadata: {totalCount: rows.length})})
    end

    it "sets up the network before learning the ip6 address" do
      expect { ln.start }.to hop("setup_leaseweb_networking")
    end

    describe "#setup_leaseweb_networking" do
      it "records an address for every ip in one snapshot, then hops to verify" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
        expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")).and_return("")

        expect {
          expect { ln.setup_leaseweb_networking }.to hop("verify_leaseweb_networking")
        }.to change { vm_host.assigned_subnets_dataset.count }.from(0).to(4)

        expect(ln.expected_addresses).to eq("ens3f0np0" => expected_addresses)
        expect(ln.expected_gateways).to eq expected_gateways
        expect(ln.expected_internal_interface).to be_nil
      end

      it "skips the addresses assemble already recorded from the same snapshot" do
        vm_host.create_addresses

        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
        expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")).and_return("")

        expect {
          expect { ln.setup_leaseweb_networking }.to hop("verify_leaseweb_networking")
        }.not_to change { vm_host.assigned_subnets_dataset.count }.from(4)
      end

      it "prunes a block Leaseweb stopped routing since assemble" do
        # A block an earlier snapshot recorded that this pull omits.
        stale = Address.create(cidr: "10.20.30.0/26", routed_to_host_id: vm_host.id, host_only: false)
        AssignedHostAddress.create(host_id: vm_host.id, ip: stale.cidr.to_s, address_id: stale.id)

        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
        expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")).and_return("")

        expect {
          expect { ln.setup_leaseweb_networking }.to hop("verify_leaseweb_networking")
        }.to change { Address[stale.id] }.to(nil)
        expect(vm_host.assigned_subnets_dataset.count).to eq(4)
        expect(DB[:ipv4_address].where(cidr: "10.20.30.0/26").count).to eq(0)
      end

      it "sends the netplan the generator produced" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
        expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")) do |command|
          netplan = YAML.safe_load(Shellwords.split(command).last)
          expect(netplan.dig("network", "ethernets", "ens3f0np0", "addresses")).to eq expected_addresses
          expect(netplan.dig("network", "ethernets")).not_to include "ens3f1np1"
          ""
        end

        expect { ln.setup_leaseweb_networking }.to hop("verify_leaseweb_networking")
      end

      context "when the server has a private network" do
        # Server 91478's private network and internal NIC, as the API reports them.
        let(:private_networks) do
          [{id: "24197", linkSpeed: 1000, status: "CONFIGURED", dhcp: "ENABLED", subnet: "10.31.2.0/27", vlanId: "2033"}]
        end
        let(:internal_nic) { {mac: "8C:84:74:54:EA:D1", ip: "10.31.2.19/27"} }

        it "addresses the internal interface statically and adds it to the state it verifies" do
          expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
          expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")) do |command|
            netplan = YAML.safe_load(Shellwords.split(command).last)
            expect(netplan.dig("network", "ethernets", "ens3f1np1")).to eq(
              "addresses" => ["10.31.2.19/27"], "mtu" => 9000, "optional" => true,
            )
            ""
          end

          expect { ln.setup_leaseweb_networking }.to hop("verify_leaseweb_networking")
          expect(ln.expected_addresses).to eq("ens3f0np0" => expected_addresses, "ens3f1np1" => ["10.31.2.19/27"])
          expect(ln.expected_internal_interface).to eq("ens3f1np1")
        end

        it "fails when no interface carries the internal mac" do
          expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link")
            .and_return(JSON.generate([{ifindex: 2, ifname: "ens3f0np0", address: "8c:84:74:54:ea:d0"}]))

          expect { ln.setup_leaseweb_networking }.to raise_error RuntimeError,
            "no interface with leaseweb internal mac 8c:84:74:54:ea:d1"
        end
      end

      it "fails when no interface carries the public mac" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link")
          .and_return(JSON.generate([{ifindex: 2, ifname: "eno1", address: "aa:bb:cc:dd:ee:ff"}]))

        expect { ln.setup_leaseweb_networking }.to raise_error RuntimeError,
          "no interface with leaseweb public mac 8c:84:74:54:ea:d0"
      end
    end

    describe "#verify_leaseweb_networking" do
      let(:ln) do
        described_class.new(Strand.new(stack: [{
          "subject_id" => vm_host.id,
          "expected_addresses" => {"ens3f0np0" => expected_addresses},
          "expected_gateways" => expected_gateways,
        }]))
      end

      it "pings each gateway and learns the ip6 once the host holds every address" do
        # The deadline is armed even on the converged path, so an unreachable
        # gateway pages instead of retrying forever when the apply was fast.
        expect(ln).to receive(:register_deadline).with("learn_ip6", 5 * 60)
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr_output)
        expect(ln.sshable).to receive(:_cmd).with("ping -c 2 -W 5 216.22.50.254").and_return("")
        expect(ln.sshable).to receive(:_cmd).with("ping6 -c 2 -W 5 2604:9a00:2100:a020::1").and_return("")

        expect { ln.verify_leaseweb_networking }.to hop("learn_ip6")
      end

      it "naps under a deadline while the kernel has not taken every address" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(unsettled_addr_output)
        expect(ln).to receive(:register_deadline).with("learn_ip6", 5 * 60)

        expect { ln.verify_leaseweb_networking }.to nap(1)
      end

      it "naps when a public address landed on the wrong interface" do
        # Placement still matters for the public NIC under tolerate: a public block
        # sitting on the internal NIC satisfies a global membership check but not
        # the per-interface one, so the host has not converged even though every
        # address is present somewhere.
        ln = described_class.new(Strand.new(stack: [{
          "subject_id" => vm_host.id,
          "expected_addresses" => {"ens3f0np0" => expected_addresses, "ens3f1np1" => ["10.31.2.19/27"]},
          "expected_gateways" => expected_gateways,
          "expected_internal_interface" => "ens3f1np1",
        }]))
        misplaced = JSON.generate([{
          ifname: "ens3f0np0",
          addr_info: [
            {local: "216.22.50.197", prefixlen: 32},
            {local: "2604:9a00:2100:a020:4::2", prefixlen: 112},
            {local: "2607:f5b7:3:104::1", prefixlen: 64},
          ],
        }, {ifname: "ens3f1np1", addr_info: [
          {local: "216.22.15.64", prefixlen: 26},
          {local: "10.31.2.19", prefixlen: 27},
        ]}])
        expect(ln).to receive(:register_deadline).with("learn_ip6", 5 * 60)
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(misplaced)

        expect { ln.verify_leaseweb_networking }.to nap(1)
      end

      context "when the server has a private network" do
        let(:ln) do
          described_class.new(Strand.new(stack: [{
            "subject_id" => vm_host.id,
            "expected_addresses" => {"ens3f0np0" => expected_addresses, "ens3f1np1" => ["10.31.2.19/27"]},
            "expected_gateways" => expected_gateways,
            "expected_internal_interface" => "ens3f1np1",
          }]))
        end

        let(:public_link) do
          {ifname: "ens3f0np0", addr_info: [
            {local: "216.22.50.197", prefixlen: 32},
            {local: "216.22.15.64", prefixlen: 26},
            {local: "2604:9a00:2100:a020:4::2", prefixlen: 112},
            {local: "2607:f5b7:3:104::1", prefixlen: 64},
          ]}
        end

        # The public path is converged in every case below, so verify hops
        # regardless of the internal port: it is tolerated, only recorded.
        before do
          expect(ln).to receive(:register_deadline).with("learn_ip6", 5 * 60)
          expect(ln.sshable).to receive(:_cmd).with("ping -c 2 -W 5 216.22.50.254").and_return("")
          expect(ln.sshable).to receive(:_cmd).with("ping6 -c 2 -W 5 2604:9a00:2100:a020::1").and_return("")
        end

        it "learns the ip6 and records the internal port up when it has carrier" do
          addr = JSON.generate([public_link,
            {ifname: "ens3f1np1", operstate: "UP", flags: ["BROADCAST", "MULTICAST", "UP", "LOWER_UP"],
             addr_info: [{local: "10.31.2.19", prefixlen: 27}]}])
          expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr)
          expect(Clog).to receive(:emit).with("leaseweb internal port state",
            {leaseweb_internal_port: {ifname: "ens3f1np1", operstate: "UP", carrier: true}}).and_call_original

          expect { ln.verify_leaseweb_networking }.to hop("learn_ip6")
        end

        it "tolerates a private port that came up, took its address, then dropped" do
          # The static /27 survives carrier loss, so presence alone would read a
          # dead port green. Record the drop, hop anyway; the port is optional.
          addr = JSON.generate([public_link,
            {ifname: "ens3f1np1", operstate: "DOWN", flags: ["BROADCAST", "MULTICAST"],
             addr_info: [{local: "10.31.2.19", prefixlen: 27}]}])
          expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr)
          expect(Clog).to receive(:emit).with("leaseweb internal port state",
            {leaseweb_internal_port: {ifname: "ens3f1np1", operstate: "DOWN", carrier: false}}).and_call_original

          expect { ln.verify_leaseweb_networking }.to hop("learn_ip6")
        end

        it "tolerates a private port whose link never came up" do
          # No carrier means networkd never installed the /27, so the interface is
          # absent from `ip -j addr`; the tolerate policy hops on the public path.
          addr = JSON.generate([public_link])
          expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr)
          expect(Clog).to receive(:emit).with("leaseweb internal port state",
            {leaseweb_internal_port: {ifname: "ens3f1np1", operstate: nil, carrier: false}}).and_call_original

          expect { ln.verify_leaseweb_networking }.to hop("learn_ip6")
        end
      end
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
