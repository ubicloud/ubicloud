# frozen_string_literal: true

require "excon"
class Hosting::LeasewebApis < Hosting::ProviderApis
  IpInfo = Data.define(:ip_address, :source_host_ip, :is_failover, :gateway) do
    # An IPv4 with a gateway sits on a switched segment whose router ARPs for
    # its members, so the host claims it in netplan and no VM may take it. A
    # gateway-less IPv4 is a block routed here, which is what VMs draw from.
    # Only the IPv4 pool asks; IPv6 addresses are drawn from net6 instead.
    def host_only? = !gateway.nil? && !ip_address.include?(":")
  end

  NetworkInterfaces = Data.define(:public_mac, :internal_mac, :internal_ip)

  IPS_PAGE_SIZE = 50

  def hardware_reset
    create_connection.post(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/powerCycle", expects: 204)
    nil
  end

  def set_server_name(server_name)
    create_connection.put(path: "/bareMetals/v2/servers/#{@provider.server_identifier}",
      body: JSON.generate(reference: server_name),
      expects: 204)
    nil
  end

  def pull_data_center
    location = pull_server.fetch("location")
    [location["site"], location["suite"], location["rack"]].compact.join("-")
  end

  # Leaseweb reports MACs upper-cased; `ip -j link` reports them lower-cased.
  # An internal MAC is reported even for a server with no private network, whose
  # internal port has no VLAN and no DHCP server behind it, so the privateNetworks
  # record rather than the MAC decides whether there is an internal interface.
  # Absent that record we leave the port alone, but a server that claims private
  # networking without one contradicts itself rather than lacking the feature.
  # A private network also carries the host's reserved VLAN address on internal.ip,
  # which we configure statically rather than trust the VLAN's DHCP to hand out, so
  # a private network with no internal.ip is the same kind of contradiction.
  def pull_network_interfaces
    server = pull_server
    nics = server.fetch("networkInterfaces")
    private_networks = server["privateNetworks"].to_a
    if server["isPrivateNetworkEnabled"] && private_networks.empty?
      fail "leaseweb server #{@provider.server_identifier} enables private networking but reports no private network"
    end

    if private_networks.any?
      internal_mac = nics.dig("internal", "mac")
      fail "leaseweb server #{@provider.server_identifier} has a private network but no internal interface" unless internal_mac
      internal_ip = presence(nics.dig("internal", "ip"))
      fail "leaseweb server #{@provider.server_identifier} has a private network but no internal address" unless internal_ip
    end
    NetworkInterfaces.new(
      public_mac: nics.fetch("public").fetch("mac").downcase,
      internal_mac: internal_mac&.downcase,
      internal_ip:,
    )
  end

  # Every IP Leaseweb routes to this server. NORMAL_IP excludes the segment's
  # NETWORK/GATEWAY/BROADCAST/ROUTER1/ROUTER2 rows, REMOTE_MANAGEMENT excludes
  # the IPMI address.
  def pull_ips
    rows = fetch_ips.select { it["networkType"] == "PUBLIC" && it["type"] == "NORMAL_IP" }
    main_row = rows.find { it["mainIp"] }
    fail "leaseweb server #{@provider.server_identifier} has no main IP" unless main_row
    # The main IP is the host's default-route next-hop neighbor, so a main row
    # without a gateway would leave the netplan with a via-less default route and
    # mark the host's own IP as VM-allocatable; refuse it rather than emit either.
    fail "leaseweb server #{@provider.server_identifier} has a main ip without a gateway" unless presence(main_row["gateway"])
    main_ip4 = parse_ip(main_row).first

    # Gateway-less IPv4s are members of a block routed to the host as a whole;
    # they collapse into one Address for the block. A gateway means the address
    # sits on a switched segment and stands alone.
    blocks = []
    singles = rows.filter_map do |row|
      address, prefix = parse_ip(row)
      gateway = presence(row["gateway"])

      if address.include?(":")
        net = NetAddr::IPv6Net.new(NetAddr.parse_ip(address), NetAddr::Mask128.new(prefix))
        ip_info(net.to_s, main_ip4, gateway)
      elsif row["mainIp"] || gateway
        ip_info("#{address}/32", main_ip4, gateway)
      else
        net = NetAddr::IPv4Net.new(NetAddr.parse_ip(address), NetAddr::Mask32.new(prefix))
        blocks << net.to_s
        nil
      end
    end

    singles + blocks.uniq.map { ip_info(it, main_ip4, nil) }
  end

  private

  def ip_info(ip_address, source_host_ip, gateway)
    IpInfo.new(ip_address:, source_host_ip:, is_failover: false, gateway:)
  end

  def presence(value)
    value if value.is_a?(String) && !value.empty?
  end

  # Leaseweb's "ip" field carries a trailing block suffix ("216.22.15.64/26"),
  # and for IPv6 an "_<prefixlen>" marker naming the prefix actually delegated
  # within that block ("2604:9a00:2100:a020:4::_112/64"). The marker wins over
  # prefixLength when present.
  def parse_ip(row)
    address = row.fetch("ip").split("/").first
    base, marker, suffix = address.rpartition("_")
    marker.empty? ? [address, row.fetch("prefixLength")] : [base, Integer(suffix, 10)]
  end

  def pull_server
    response = create_connection.get(path: "/bareMetals/v2/servers/#{@provider.server_identifier}", expects: 200)
    JSON.parse(response.body)
  end

  def fetch_ips
    connection = create_connection
    ips = []
    seen = Set.new
    total = nil

    loop do
      response = connection.get(path: "/bareMetals/v2/servers/#{@provider.server_identifier}/ips",
        query: {limit: IPS_PAGE_SIZE, offset: ips.length},
        expects: 200)
      body = JSON.parse(response.body)
      page = body.fetch("ips")
      # create_addresses, prune_addresses, and the netplan treat this list as the
      # host's whole routed set, so a repeated or miscounted response would delete
      # and stop routing still-live blocks. A repeat also hides a missing row
      # behind a matching count, and a server that ignores offset would re-serve a
      # full page forever, so reject a duplicate the instant it arrives rather than
      # after the loop -- which also ends a pull that would otherwise never stop.
      page.each do |row|
        fail "leaseweb server #{@provider.server_identifier} repeated an ip in its ip list" unless seen.add?(row.fetch("ip"))
      end
      ips.concat(page)
      total = body.dig("_metadata", "totalCount")
      # A full page can hide more rows, so page until a short one ends the list;
      # stopping at totalCount would accept a set a lagging count undercounts.
      break if page.length < IPS_PAGE_SIZE
    end

    # The ips are now guaranteed distinct, so demand the promised count of them.
    fail "leaseweb server #{@provider.server_identifier} returned #{ips.length} of #{total} ips" unless ips.length == total

    ips
  end

  def create_connection
    Excon.new(Config.leaseweb_connection_string,
      headers: {"X-Lsw-Auth" => Config.leaseweb_api_key, "Content-Type" => "application/json"})
  end
end
