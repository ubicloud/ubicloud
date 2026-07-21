# frozen_string_literal: true

require "excon"
class Hosting::LeasewebApis < Hosting::ProviderApis
  IpInfo = Data.define(:ip_address, :source_host_ip, :is_failover, :gateway) do
    # A gatewayed IPv4 sits on a switched segment the host must claim (no VM may
    # take it); a gateway-less IPv4 is a block routed here that VMs draw from.
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

  # Leaseweb reports MACs upper-cased; `ip -j link` lower-cases them. The
  # privateNetworks record, not the internal MAC (present even without one),
  # decides whether there is an internal interface, and carries the host's
  # statically-configured VLAN address on internal.ip.
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

  # NORMAL_IP excludes the segment's NETWORK/GATEWAY/BROADCAST/ROUTER rows;
  # PUBLIC excludes the REMOTE_MANAGEMENT (IPMI) address.
  def pull_ips
    rows = fetch_ips.select { it["networkType"] == "PUBLIC" && it["type"] == "NORMAL_IP" }
    main_row = rows.find { it["mainIp"] }
    fail "leaseweb server #{@provider.server_identifier} has no main IP" unless main_row
    fail "leaseweb server #{@provider.server_identifier} has a main ip without a gateway" unless presence(main_row["gateway"])
    main_ip4 = parse_ip(main_row).first

    # Gateway-less IPv4s collapse into one Address per routed block; the rest
    # stand alone as /32s.
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
  # and for IPv6 an "_<prefixlen>" marker naming the delegated prefix within it
  # ("2604:9a00:2100:a020:4::_112/64"). The marker wins over prefixLength.
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
      # This list is the host's whole routed set, so fail on a repeat: it masks a
      # dropped row behind the count and can loop an offset-ignoring server.
      page.each do |row|
        fail "leaseweb server #{@provider.server_identifier} repeated an ip in its ip list" unless seen.add?(row.fetch("ip"))
      end
      ips.concat(page)
      total = body.dig("_metadata", "totalCount")
      # Page until a short page ends the list; totalCount can lag the rows served.
      break if page.length < IPS_PAGE_SIZE
    end

    fail "leaseweb server #{@provider.server_identifier} returned #{ips.length} of #{total} ips" unless ips.length == total

    ips
  end

  def create_connection
    Excon.new(Config.leaseweb_connection_string,
      headers: {"X-Lsw-Auth" => Config.leaseweb_api_key, "Content-Type" => "application/json"})
  end
end
