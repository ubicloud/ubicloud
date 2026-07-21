# frozen_string_literal: true

RSpec.describe Hosting::LeasewebNetplan do
  def ip_info(ip_address, gateway = nil, source_host_ip: "216.22.50.197")
    Hosting::LeasewebApis::IpInfo.new(ip_address:, source_host_ip:, is_failover: false, gateway:)
  end

  # What pull_ips returns for server 12493302, the hand-configured reference.
  let(:reference_ip_infos) do
    [
      ip_info("216.22.50.197/32", "216.22.50.254"),
      ip_info("2604:9a00:2100:a020:4::/112", "2604:9a00:2100:a020::1"),
      ip_info("2607:f5b7:3:104::/64"),
      ip_info("216.22.15.64/26"),
    ]
  end

  # 12493302 reports no private network, so pull_network_interfaces gives it no
  # internal interface even though it reports an internal MAC.
  let(:netplan) do
    described_class.new(public_interface: "ens3f0np0", internal_interface: nil, internal_ip: nil, ip_infos: reference_ip_infos)
  end

  # /etc/netplan/01-netcfg.yaml as hand-written on 12493302, less its second
  # default route via the host's own address, and less its ens3f1np1 stanza: the
  # hand-written file configures dhcp4 on an internal port with no private
  # network behind it, which puts the port in netplan's -i <iface>:degraded
  # wait-online list and delays every boot. It also gains accept-ra, which the
  # hand-written file leaves at networkd's default of on. Compared parsed rather
  # than byte for byte: the hand-written file mixes indent widths and quoting
  # styles, neither of which YAML gives meaning to.
  let(:reference_netplan) do
    <<~YAML
      network:
          version: 2
          renderer: networkd
          ethernets:
              ens3f0np0:
                  dhcp4: no
                  dhcp6: no
                  accept-ra: no
                  addresses:
                    - '216.22.50.197/32'
                    - '216.22.15.64/26'
                    - '2604:9a00:2100:a020:4::2/112'
                    - '2607:f5b7:3:104::1/64'
                  routes:
                      - to: default
                        via: 216.22.50.254
                        metric: 100
                        on-link: true
                      - to: default
                        via: 2604:9a00:2100:a020::1
                        metric: 100
                        on-link: true
                  nameservers:
                      search: ['dedi.leaseweb.net']
                      addresses: ['23.19.53.53', '23.19.52.52']
    YAML
  end

  it "reproduces the hand-written netplan of server 12493302, less its internal stanza" do
    expect(YAML.safe_load(netplan.to_yaml)).to eq YAML.safe_load(reference_netplan)
  end

  it "claims ::2 out of a connectivity prefix and ::1 out of a routed prefix" do
    expect(netplan.interface_addresses).to eq(
      "ens3f0np0" => [
        "216.22.50.197/32",
        "216.22.15.64/26",
        "2604:9a00:2100:a020:4::2/112",
        "2607:f5b7:3:104::1/64",
      ],
    )
  end

  it "routes by default through the main ipv4 gateway and the ipv6 gateway only" do
    expect(netplan.gateways).to eq ["216.22.50.254", "2604:9a00:2100:a020::1"]
  end

  it "omits the internal ethernet when the server has no private network" do
    expect(netplan.to_h.dig("network", "ethernets").keys).to eq ["ens3f0np0"]
  end

  # Server 91478's shape. The internal NIC takes its reserved VLAN address
  # statically, not over DHCP, so a VLAN whose DHCP is disabled still gets
  # addressed. `optional: true` keeps the port out of the `-i <iface>:degraded`
  # list netplan generates for systemd-networkd-wait-online, so a private port
  # whose link never comes up cannot stall boot.
  it "addresses the internal ethernet statically when the server has a private network" do
    netplan = described_class.new(public_interface: "eno0", internal_interface: "eno1", internal_ip: "10.31.2.19/27", ip_infos: reference_ip_infos)
    expect(netplan.to_h.dig("network", "ethernets", "eno1")).to eq(
      "addresses" => ["10.31.2.19/27"], "mtu" => 9000, "optional" => true,
    )
  end

  it "never marks the public ethernet optional" do
    netplan = described_class.new(public_interface: "eno0", internal_interface: "eno1", internal_ip: "10.31.2.19/27", ip_infos: reference_ip_infos)
    expect(netplan.to_h.dig("network", "ethernets", "eno0")).not_to include "optional"
  end

  # The internal VLAN address joins the desired state the prog verifies the host
  # converged on, keyed to the internal NIC, never the public one.
  it "keys the internal address to the internal interface, never the public one" do
    netplan = described_class.new(public_interface: "eno0", internal_interface: "eno1", internal_ip: "10.31.2.19/27", ip_infos: reference_ip_infos)
    expect(netplan.interface_addresses).to eq(
      "eno0" => [
        "216.22.50.197/32",
        "216.22.15.64/26",
        "2604:9a00:2100:a020:4::2/112",
        "2607:f5b7:3:104::1/64",
      ],
      "eno1" => ["10.31.2.19/27"],
    )
  end

  # netplan renders this as IPv6AcceptRA=no. Without it networkd accepts router
  # advertisements even though dhcp6 is off, so the host would take a default
  # route from the segment's router if ours ever went missing.
  it "refuses router advertisements on the public ethernet" do
    expect(netplan.to_h.dig("network", "ethernets", "ens3f0np0", "accept-ra")).to be false
  end

  # Server 91478's extra IPv4s sit on a switched /29 behind their own gateway.
  # The host claims each as a /32, so the segment never becomes a connected
  # route. Its gateway resolves to the same router as the main one, so it must
  # not add a second default route.
  it "claims gatewayed non-main ipv4s as /32 without routing through their gateway" do
    netplan = described_class.new(public_interface: "eno1", internal_interface: nil, internal_ip: nil, ip_infos: [
      ip_info("23.105.171.112/32", "23.105.171.126", source_host_ip: "23.105.171.112"),
      ip_info("23.105.176.3/32", "23.105.176.6", source_host_ip: "23.105.171.112"),
      ip_info("23.105.176.1/32", "23.105.176.6", source_host_ip: "23.105.171.112"),
      ip_info("23.105.176.2/32", "23.105.176.6", source_host_ip: "23.105.171.112"),
      ip_info("2607:f5b7:1:30:9::/112", "2607:f5b7:1:30::1", source_host_ip: "23.105.171.112"),
    ])

    expect(netplan.interface_addresses).to eq(
      "eno1" => [
        "23.105.171.112/32",
        "23.105.176.1/32",
        "23.105.176.2/32",
        "23.105.176.3/32",
        "2607:f5b7:1:30:9::2/112",
      ],
    )
    expect(netplan.gateways).to eq ["23.105.171.126", "2607:f5b7:1:30::1"]
  end

  it "sorts multiple routed ipv4 blocks by network address" do
    netplan = described_class.new(public_interface: "eno1", internal_interface: nil, internal_ip: nil, ip_infos: [
      ip_info("216.22.50.197/32", "216.22.50.254"),
      ip_info("216.22.60.0/26"),
      ip_info("216.22.15.64/26"),
    ])

    expect(netplan.interface_addresses).to eq("eno1" => ["216.22.50.197/32", "216.22.15.64/26", "216.22.60.0/26"])
  end

  it "fails when no address matches the source host ip" do
    expect {
      described_class.new(public_interface: "eno1", internal_interface: nil, internal_ip: nil, ip_infos: [ip_info("216.22.15.64/26")])
    }.to raise_error RuntimeError, "no main IPv4 address among leaseweb ip infos"
  end
end
