# frozen_string_literal: true

RSpec.describe Hosting::LeasewebApis do
  let(:leaseweb_apis) do
    vmh = create_vm_host
    vmh.sshable.update(host: "216.22.50.197")
    provider = HostProvider.create do
      it.id = vmh.id
      it.server_identifier = "123"
      it.provider_name = HostProvider::LEASEWEB_PROVIDER_NAME
    end
    described_class.new(provider)
  end

  before do
    allow(Config).to receive_messages(
      leaseweb_connection_string: "https://api.leaseweb.com",
      leaseweb_api_key: "key123",
    )
  end

  def ip_row(ip, prefix_length:, type: "NORMAL_IP", network_type: "PUBLIC", main_ip: false, gateway: "")
    {"ip" => ip, "prefixLength" => prefix_length, "type" => type, "networkType" => network_type,
     "mainIp" => main_ip, "gateway" => gateway}
  end

  def stub_ips(pages)
    total = pages.sum(&:length)
    offset = 0
    pages.each do |page|
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset:}},
        {status: 200, body: JSON.generate(ips: page, _metadata: {totalCount: total})})
      offset += page.length
    end
  end

  # Real /ips output for server 12493302: the whole /26 is routed to the host
  # (every address NORMAL_IP, no gateway), the main IP stands alone behind a
  # gateway, and two IPv6 prefixes arrive with an "_<prefixlen>" marker.
  def reference_ip_rows
    block = (64..127).map { ip_row("216.22.15.#{it}/26", prefix_length: 26) }
    [
      ip_row("10.59.61.133/26", prefix_length: 26, type: "IPMI", network_type: "REMOTE_MANAGEMENT", gateway: "10.59.61.190"),
      *block,
      ip_row("216.22.50.197/26", prefix_length: 26, main_ip: true, gateway: "216.22.50.254"),
      ip_row("2604:9a00:2100:a020:4::_112/64", prefix_length: 64, gateway: "2604:9a00:2100:a020::1"),
      ip_row("2607:f5b7:3:104::_64/64", prefix_length: 64),
    ]
  end

  # Real /ips output for server 91478: its extra IPv4s arrive as a switched /29
  # whose infra addresses are typed, and every row of which carries the segment
  # gateway. It has no routed IPv4 block and a single IPv6 prefix.
  def segment_ip_rows
    [
      ip_row("10.59.22.90/26", prefix_length: 26, type: "IPMI", network_type: "REMOTE_MANAGEMENT", gateway: "10.59.22.126"),
      ip_row("23.105.171.112/26", prefix_length: 26, main_ip: true, gateway: "23.105.171.126"),
      ip_row("23.105.176.0/29", prefix_length: 29, type: "NETWORK", gateway: "23.105.176.6"),
      ip_row("23.105.176.1/29", prefix_length: 29, gateway: "23.105.176.6"),
      ip_row("23.105.176.2/29", prefix_length: 29, gateway: "23.105.176.6"),
      ip_row("23.105.176.3/29", prefix_length: 29, gateway: "23.105.176.6"),
      ip_row("23.105.176.4/29", prefix_length: 29, type: "ROUTER1", gateway: "23.105.176.6"),
      ip_row("23.105.176.5/29", prefix_length: 29, type: "ROUTER2", gateway: "23.105.176.6"),
      ip_row("23.105.176.6/29", prefix_length: 29, type: "GATEWAY", gateway: "23.105.176.6"),
      ip_row("23.105.176.7/29", prefix_length: 29, type: "BROADCAST", gateway: "23.105.176.6"),
      ip_row("2607:f5b7:1:30:9::_112/64", prefix_length: 64, gateway: "2607:f5b7:1:30::1"),
    ]
  end

  def ip_info(ip_address, gateway)
    described_class::IpInfo.new(ip_address:, source_host_ip: "216.22.50.197", is_failover: false, gateway:)
  end

  describe "hardware_reset" do
    it "can power cycle a server" do
      Excon.stub({path: "/bareMetals/v2/servers/123/powerCycle", method: :post}, {status: 204, body: ""})
      expect(leaseweb_apis.hardware_reset).to be_nil
    end
  end

  describe "set_server_name" do
    it "updates the server reference" do
      Excon.stub({path: "/bareMetals/v2/servers/123", method: :put, body: JSON.generate(reference: "vh123")}, {status: 204, body: ""})
      expect(leaseweb_apis.set_server_name("vh123")).to be_nil
    end
  end

  describe "pull_data_center" do
    it "returns the site and suite" do
      Excon.stub({path: "/bareMetals/v2/servers/123", method: :get}, {status: 200, body: JSON.generate(location: {site: "WDC-02", suite: "SC03.03A", rack: "F10"})})
      expect(leaseweb_apis.pull_data_center).to eq "WDC-02-SC03.03A-F10"
    end
  end

  describe "pull_network_interfaces" do
    def stub_server(**body)
      Excon.stub({path: "/bareMetals/v2/servers/123", method: :get}, {status: 200, body: JSON.generate(body)})
    end

    # Server 91478's private network, as the API reports it.
    def private_network
      {id: "24197", linkSpeed: 1000, status: "CONFIGURED", dhcp: "ENABLED", subnet: "10.31.2.0/27", vlanId: "2033"}
    end

    def both_macs
      {public: {mac: "8C:84:74:54:EA:D0"}, internal: {mac: "8C:84:74:54:EA:D1"}}
    end

    # Server 91478's shape: a private network carries the host's reserved VLAN
    # address on internal.ip.
    it "downcases the macs and keeps the internal interface's reserved address" do
      stub_server(networkInterfaces: {public: {mac: "28:92:4A:34:29:FA"}, internal: {mac: "28:92:4A:34:29:FB", ip: "10.31.2.19/27"}},
        isPrivateNetworkEnabled: true, privateNetworks: [private_network])
      expect(leaseweb_apis.pull_network_interfaces).to eq described_class::NetworkInterfaces.new(
        public_mac: "28:92:4a:34:29:fa", internal_mac: "28:92:4a:34:29:fb", internal_ip: "10.31.2.19/27",
      )
    end

    # Server 12493302 reports an internal MAC although it has no private network;
    # its internal port has no VLAN and nothing answering DHCP behind it, and its
    # internal.ip is null.
    it "reports no internal mac or address when the server has no private network" do
      stub_server(networkInterfaces: both_macs, isPrivateNetworkEnabled: false, privateNetworks: [])
      expect(leaseweb_apis.pull_network_interfaces).to eq described_class::NetworkInterfaces.new(
        public_mac: "8c:84:74:54:ea:d0", internal_mac: nil, internal_ip: nil,
      )
    end

    it "reports no internal mac when the api omits the private networks" do
      stub_server(networkInterfaces: both_macs)
      expect(leaseweb_apis.pull_network_interfaces.internal_mac).to be_nil
    end

    it "reports no internal mac when the api nulls the private networks" do
      stub_server(networkInterfaces: both_macs, privateNetworks: nil)
      expect(leaseweb_apis.pull_network_interfaces.internal_mac).to be_nil
    end

    # Silently dropping the internal interface in either case would leave a host
    # that wants private networking without it; a missing record is only safe to
    # ignore when the server does not claim the feature at all.
    it "fails when the server enables private networking but reports no private network" do
      stub_server(networkInterfaces: both_macs, isPrivateNetworkEnabled: true, privateNetworks: [])
      expect { leaseweb_apis.pull_network_interfaces }.to raise_error RuntimeError,
        "leaseweb server 123 enables private networking but reports no private network"
    end

    it "fails when the api nulls the private networks of a server that enables them" do
      stub_server(networkInterfaces: both_macs, isPrivateNetworkEnabled: true, privateNetworks: nil)
      expect { leaseweb_apis.pull_network_interfaces }.to raise_error RuntimeError,
        "leaseweb server 123 enables private networking but reports no private network"
    end

    it "fails when the server has a private network but no internal interface" do
      stub_server(networkInterfaces: {public: {mac: "28:92:4A:34:29:FA"}},
        isPrivateNetworkEnabled: true, privateNetworks: [private_network])
      expect { leaseweb_apis.pull_network_interfaces }.to raise_error RuntimeError,
        "leaseweb server 123 has a private network but no internal interface"
    end

    # A private network we cannot address is as much a contradiction as one with
    # no internal port: fail rather than emit an addressless internal ethernet.
    it "fails when the server has a private network but no internal address" do
      stub_server(networkInterfaces: {public: {mac: "28:92:4A:34:29:FA"}, internal: {mac: "28:92:4A:34:29:FB", ip: nil}},
        isPrivateNetworkEnabled: true, privateNetworks: [private_network])
      expect { leaseweb_apis.pull_network_interfaces }.to raise_error RuntimeError,
        "leaseweb server 123 has a private network but no internal address"
    end
  end

  describe "pull_ips" do
    it "collapses a routed block, keeps the main ip and both ipv6 prefixes, and pages" do
      rows = reference_ip_rows
      stub_ips([rows.take(50), rows.drop(50)])

      expect(leaseweb_apis.pull_ips).to eq [
        ip_info("216.22.50.197/32", "216.22.50.254"),
        ip_info("2604:9a00:2100:a020:4::/112", "2604:9a00:2100:a020::1"),
        ip_info("2607:f5b7:3:104::/64", nil),
        ip_info("216.22.15.64/26", nil),
      ]
    end

    # Server 91478 delivers its extra IPv4s as a switched /29: the infra rows are
    # typed, and every row carries the segment's gateway.
    it "keeps gatewayed non-main ipv4s as single addresses and drops typed infra rows" do
      stub_ips([segment_ip_rows])

      expect(leaseweb_apis.pull_ips.map { [it.ip_address, it.gateway] }).to eq [
        ["23.105.171.112/32", "23.105.171.126"],
        ["23.105.176.1/32", "23.105.176.6"],
        ["23.105.176.2/32", "23.105.176.6"],
        ["23.105.176.3/32", "23.105.176.6"],
        ["2607:f5b7:1:30:9::/112", "2607:f5b7:1:30::1"],
      ]
    end

    # The host claims every gatewayed IPv4 in netplan, so none of them may reach
    # the VM pool. A routed block is what VMs draw from, and IPv6 never populates
    # that pool.
    it "marks gatewayed ipv4s host only and leaves routed blocks allocatable" do
      stub_ips([segment_ip_rows + [ip_row("216.22.15.64/26", prefix_length: 26)]])

      expect(leaseweb_apis.pull_ips.map { [it.ip_address, it.host_only?] }).to eq [
        ["23.105.171.112/32", true],
        ["23.105.176.1/32", true],
        ["23.105.176.2/32", true],
        ["23.105.176.3/32", true],
        ["2607:f5b7:1:30:9::/112", false],
        ["216.22.15.64/26", false],
      ]
    end

    # A short page that falls short of the promised total is a truncated snapshot.
    # Reconciling it would prune Address rows and stop routing blocks Leaseweb
    # still carries, so the pull fails instead of handing prune_addresses less.
    it "fails on a truncated page rather than returning a partial ip list" do
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(ips: [ip_row("216.22.50.197/26", prefix_length: 26, main_ip: true, gateway: "216.22.50.254")], _metadata: {totalCount: 9})})

      expect { leaseweb_apis.pull_ips }.to raise_error RuntimeError, "leaseweb server 123 returned 1 of 9 ips"
    end

    # A response that repeats a row holds fewer distinct ips than it promises, so
    # it is still partial. A repeat also hides a missing row behind a low count
    # that matches after dedup, so any duplicate fails outright rather than let
    # prune_addresses delete the ips it silently dropped.
    it "fails when a page repeats a row even where dedup would match the count" do
      main = ip_row("216.22.50.197/26", prefix_length: 26, main_ip: true, gateway: "216.22.50.254")
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(ips: [main, main], _metadata: {totalCount: 1})})

      expect { leaseweb_apis.pull_ips }.to raise_error RuntimeError, "leaseweb server 123 repeated an ip in its ip list"
    end

    # A server that ignores offset re-serves the same full page, which never ends
    # the pager on its own. The first ip repeated across pages stops it before it
    # loops forever concatenating the same rows.
    it "fails when a later page repeats an ip from an earlier full page" do
      page = (1..50).map { ip_row("23.0.0.#{it}/32", prefix_length: 32, gateway: "23.0.0.254") }
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(ips: page, _metadata: {totalCount: 100})})
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 50}},
        {status: 200, body: JSON.generate(ips: page, _metadata: {totalCount: 100})})

      expect { leaseweb_apis.pull_ips }.to raise_error RuntimeError, "leaseweb server 123 repeated an ip in its ip list"
    end

    # totalCount can lag the rows a full page already serves. Stopping at it would
    # drop the routed ips still waiting at the next offset, so the pager reads on
    # until a short page and only then trusts the (now consistent) count.
    it "pages past a full page whose totalCount already matches it" do
      main = ip_row("216.22.50.197/26", prefix_length: 26, main_ip: true, gateway: "216.22.50.254")
      filler = (1..49).map { ip_row("23.0.0.#{it}/32", prefix_length: 32, gateway: "23.0.0.254") }
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 0}},
        {status: 200, body: JSON.generate(ips: [main] + filler, _metadata: {totalCount: 50})})
      Excon.stub({path: "/bareMetals/v2/servers/123/ips", query: {limit: 50, offset: 50}},
        {status: 200, body: JSON.generate(ips: [ip_row("216.22.15.64/26", prefix_length: 26)], _metadata: {totalCount: 51})})

      expect(leaseweb_apis.pull_ips.map(&:ip_address)).to include("216.22.15.64/26")
    end

    it "fails when the server has no main ip" do
      stub_ips([[ip_row("216.22.15.65/26", prefix_length: 26)]])
      expect { leaseweb_apis.pull_ips }.to raise_error RuntimeError, "leaseweb server 123 has no main IP"
    end

    it "fails when the main ip has no gateway" do
      stub_ips([[ip_row("216.22.50.197/26", prefix_length: 26, main_ip: true)]])
      expect { leaseweb_apis.pull_ips }.to raise_error RuntimeError, "leaseweb server 123 has a main ip without a gateway"
    end
  end

  describe "unimplemented operations" do
    it "does not respond to operations leaseweb does not implement" do
      [:reimage, :get_main_ip4].each do |operation|
        expect(leaseweb_apis).not_to respond_to(operation)
      end
    end
  end
end
