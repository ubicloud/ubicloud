# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Leaseweb::SetupNetworking do
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

  let(:resolv_conf_output) { "nameserver 23.19.53.53\nnameserver 23.19.52.52\nsearch dedi.leaseweb.net\n" }

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

    stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/123")
      .to_return(status: 200, body: JSON.generate(networkInterfaces: {public: {mac: "8C:84:74:54:EA:D0"}, internal: internal_nic},
        isPrivateNetworkEnabled: private_networks.any?, privateNetworks: private_networks))

    block = (64..127).map do
      {ip: "216.22.15.#{it}/26", prefixLength: 26, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: ""}
    end
    rows = [
      *block,
      {ip: "216.22.50.197/26", prefixLength: 26, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: true, gateway: "216.22.50.254"},
      {ip: "2604:9a00:2100:a020:4::_112/64", prefixLength: 64, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: "2604:9a00:2100:a020::1"},
      {ip: "2607:f5b7:3:104::_64/64", prefixLength: 64, type: "NORMAL_IP", networkType: "PUBLIC", mainIp: false, gateway: ""},
    ]
    stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/123/ips").with(query: {limit: 50, offset: 0})
      .to_return(status: 200, body: JSON.generate(ips: rows.take(50), _metadata: {totalCount: rows.length}))
    stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/123/ips").with(query: {limit: 50, offset: 50})
      .to_return(status: 200, body: JSON.generate(ips: rows.drop(50), _metadata: {totalCount: rows.length}))
  end

  describe "#start" do
    it "records an address for every ip in one snapshot, then hops to verify" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
      expect(ln.sshable).to receive(:_cmd).with("cat /run/systemd/resolve/resolv.conf").and_return(resolv_conf_output)
      expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")).and_return("")

      expect {
        expect { ln.start }.to hop("verify")
      }.to change { vm_host.assigned_subnets_dataset.count }.from(0).to(3)

      # The gatewayed /112 is host connectivity: in the netplan, not the registry.
      expect(vm_host.assigned_subnets.map { it.cidr.to_s }.sort).to eq(
        ["216.22.15.64/26", "216.22.50.197/32", "2607:f5b7:3:104::/64"],
      )

      expect(ln.expected_addresses).to eq("ens3f0np0" => expected_addresses)
      expect(ln.expected_gateways).to eq expected_gateways
      expect(ln.expected_internal_interface).to be_nil
    end

    it "skips the addresses assemble already recorded from the same snapshot" do
      vm_host.create_addresses

      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
      expect(ln.sshable).to receive(:_cmd).with("cat /run/systemd/resolve/resolv.conf").and_return(resolv_conf_output)
      expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")).and_return("")

      expect {
        expect { ln.start }.to hop("verify")
      }.not_to change { vm_host.assigned_subnets_dataset.count }.from(3)
    end

    it "sends the netplan the generator produced" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
      expect(ln.sshable).to receive(:_cmd).with("cat /run/systemd/resolve/resolv.conf").and_return(resolv_conf_output)
      expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")) do |command|
        netplan = YAML.safe_load(Shellwords.split(command).last)
        expect(netplan.dig("network", "ethernets", "ens3f0np0", "addresses")).to eq expected_addresses
        expect(netplan.dig("network", "ethernets", "ens3f0np0", "nameservers")).to eq("search" => ["dedi.leaseweb.net"], "addresses" => ["23.19.53.53", "23.19.52.52"])
        expect(netplan.dig("network", "ethernets")).not_to include "ens3f1np1"
        ""
      end

      expect { ln.start }.to hop("verify")
    end

    context "when the server has a private network" do
      # Server 91478's private network and internal NIC, as the API reports them.
      let(:private_networks) do
        [{id: "24197", linkSpeed: 1000, status: "CONFIGURED", dhcp: "ENABLED", subnet: "10.31.2.0/27", vlanId: "2033"}]
      end
      let(:internal_nic) { {mac: "8C:84:74:54:EA:D1", ip: "10.31.2.19/27"} }

      it "addresses the internal interface statically and adds it to the state it verifies" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
        expect(ln.sshable).to receive(:_cmd).with("cat /run/systemd/resolve/resolv.conf").and_return(resolv_conf_output)
        expect(ln.sshable).to receive(:_cmd).with(a_string_starting_with("sudo host/bin/setup-leaseweb-networking")) do |command|
          netplan = YAML.safe_load(Shellwords.split(command).last)
          expect(netplan.dig("network", "ethernets", "ens3f1np1")).to eq(
            "addresses" => ["10.31.2.19/27"], "mtu" => 9000, "optional" => true,
          )
          ""
        end

        expect { ln.start }.to hop("verify")
        expect(ln.expected_addresses).to eq("ens3f0np0" => expected_addresses, "ens3f1np1" => ["10.31.2.19/27"])
        expect(ln.expected_internal_interface).to eq("ens3f1np1")
      end

      it "fails when no interface carries the internal mac" do
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link")
          .and_return(JSON.generate([{ifindex: 2, ifname: "ens3f0np0", address: "8c:84:74:54:ea:d0"}]))

        expect { ln.start }.to raise_error RuntimeError,
          "no interface with leaseweb internal mac 8c:84:74:54:ea:d1"
      end
    end

    it "fails when no interface carries the public mac" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link")
        .and_return(JSON.generate([{ifindex: 2, ifname: "eno1", address: "aa:bb:cc:dd:ee:ff"}]))

      expect { ln.start }.to raise_error RuntimeError,
        "no interface with leaseweb public mac 8c:84:74:54:ea:d0"
    end

    it "fails when the host reports no upstream resolvers" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j link").and_return(link_output)
      expect(ln.sshable).to receive(:_cmd).with("cat /run/systemd/resolve/resolv.conf").and_return("# operation timed out\n")
      expect { ln.start }.to raise_error RuntimeError, "no upstream resolvers on the host"
    end
  end

  describe "#verify" do
    let(:ln) do
      described_class.new(Strand.new(stack: [{
        "subject_id" => vm_host.id,
        "expected_addresses" => {"ens3f0np0" => expected_addresses},
        "expected_gateways" => expected_gateways,
      }]))
    end

    it "pings each gateway and refreshes nftables once the host holds every address" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr_output)
      expect(ln.sshable).to receive(:_cmd).with("sudo ping -c 2 -W 5 216.22.50.254").and_return("")
      expect(ln.sshable).to receive(:_cmd).with("sudo ping6 -c 2 -W 5 2604:9a00:2100:a020::1").and_return("")

      expect { ln.verify }.to hop("refresh_nftables")
    end

    it "naps while the kernel has not taken every address" do
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(unsettled_addr_output)

      expect { ln.verify }.to nap(1)
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
      expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(misplaced)

      expect { ln.verify }.to nap(1)
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
        expect(ln.sshable).to receive(:_cmd).with("sudo ping -c 2 -W 5 216.22.50.254").and_return("")
        expect(ln.sshable).to receive(:_cmd).with("sudo ping6 -c 2 -W 5 2604:9a00:2100:a020::1").and_return("")
      end

      it "records the internal port up when it has carrier" do
        addr = JSON.generate([public_link,
          {ifname: "ens3f1np1", operstate: "UP", flags: ["BROADCAST", "MULTICAST", "UP", "LOWER_UP"],
           addr_info: [{local: "10.31.2.19", prefixlen: 27}]}])
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr)
        expect(Clog).to receive(:emit).with("leaseweb internal port state",
          {leaseweb_internal_port: {ifname: "ens3f1np1", operstate: "UP", carrier: true}}).and_call_original

        expect { ln.verify }.to hop("refresh_nftables")
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

        expect { ln.verify }.to hop("refresh_nftables")
      end

      it "tolerates a private port whose link never came up" do
        # No carrier means networkd never installed the /27, so the interface is
        # absent from `ip -j addr`; the tolerate policy hops on the public path.
        addr = JSON.generate([public_link])
        expect(ln.sshable).to receive(:_cmd).with("/usr/sbin/ip -j addr").and_return(addr)
        expect(Clog).to receive(:emit).with("leaseweb internal port state",
          {leaseweb_internal_port: {ifname: "ens3f1np1", operstate: nil, carrier: false}}).and_call_original

        expect { ln.verify }.to hop("refresh_nftables")
      end
    end
  end

  describe "#refresh_nftables" do
    let(:ln) do
      described_class.new(Strand.create_with_id(Strand.generate_uuid,
        prog: "Leaseweb::SetupNetworking", label: "refresh_nftables", stack: [{"subject_id" => vm_host.id}]))
    end

    it "reruns nftables against the final address set" do
      expect { ln.refresh_nftables }.to hop("start", "SetupNftables")
    end

    it "pops once nftables was rewritten" do
      ln.strand.retval = {"msg" => "nftables was setup"}
      expect { ln.refresh_nftables }.to exit({"msg" => "leaseweb networking configured"})
    end
  end
end
