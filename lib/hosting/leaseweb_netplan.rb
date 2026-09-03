# frozen_string_literal: true

require "yaml"

# Builds the desired-state /etc/netplan/01-netcfg.yaml for a Leaseweb host
# from its ip records, NIC MACs, and the resolvers its environment provided.
class Hosting::LeasewebNetplan
  ROUTE_METRIC = 100
  INTERNAL_MTU = 9000

  # The host claims ::2 out of a connectivity prefix, whose gateway lives
  # outside it in the parent block, and ::1 out of a prefix routed to it.
  CONNECTIVITY_HOST_OFFSET = 2
  ROUTED_HOST_OFFSET = 1

  def initialize(public_mac:, internal_mac:, internal_ip:, ip_infos:, nameservers:, search_domains:)
    @public_mac = public_mac
    @internal_mac = internal_mac
    @internal_ip = internal_ip
    @ip_infos = ip_infos
    @nameservers = nameservers
    @search_domains = search_domains
    @main = ip_infos.find { it.ip_address == "#{it.source_host_ip}/32" }
    fail "no main IPv4 address among leaseweb ip infos" unless @main
  end

  def to_yaml
    YAML.dump(to_h)
  end

  def to_h
    ethernets = {"public" => public_ethernet}
    ethernets["internal"] = internal_ethernet if @internal_mac

    {"network" => {"version" => 2, "renderer" => "networkd", "ethernets" => ethernets}}
  end

  # Desired addresses keyed by the MAC each belongs to, so verify can check
  # placement, not mere presence, without depending on a name the firmware
  # is free to reassign.
  def addresses_by_mac
    macs = {@public_mac => public_addresses}
    macs[@internal_mac] = internal_addresses if @internal_mac
    macs
  end

  # One default route per family; a segment gateway resolves to the same router.
  def gateways
    [@main.gateway] + ipv6.filter_map(&:gateway)
  end

  private

  # Main IP, switched-segment IPs, IPv4 blocks, then the host address per IPv6 prefix.
  def public_addresses
    [@main.ip_address] + (ipv4_segment + ipv4_blocks).map(&:ip_address) + ipv6.map { host_address(it) }
  end

  def internal_addresses
    [@internal_ip]
  end

  # Declare the reserved VLAN address (a DHCP-disabled VLAN still gets addressed).
  # optional keeps a dead private port from stalling network-online.target.
  def internal_ethernet
    {"match" => {"macaddress" => @internal_mac}, "addresses" => internal_addresses, "mtu" => INTERNAL_MTU, "optional" => true}
  end

  # accept-ra false: dhcp6 off still accepts router advertisements, which would
  # add a competing default route / SLAAC address; this file is the whole state.
  def public_ethernet
    {
      "match" => {"macaddress" => @public_mac},
      "dhcp4" => false,
      "dhcp6" => false,
      "accept-ra" => false,
      "addresses" => public_addresses,
      "routes" => routes,
      "nameservers" => {"search" => @search_domains, "addresses" => @nameservers},
    }
  end

  def routes
    gateways.map do |gateway|
      {"to" => "default", "via" => gateway, "metric" => ROUTE_METRIC, "on-link" => true}
    end
  end

  def ipv4
    @ip_infos.reject { it.ip_address.include?(":") || it == @main }
  end

  # Switched-segment members (gatewayed); pull_ips yields /32s so the host holds
  # only these, not the whole segment.
  def ipv4_segment
    sorted_ipv4(ipv4.select(&:gateway))
  end

  # A block of one or two addresses is a standalone VM address Leaseweb
  # routes here, not a block the host anchors. Claiming it on the NIC would
  # pull the VM's inbound into the host's local table.
  def ipv4_blocks
    sorted_ipv4(ipv4.reject(&:gateway).select { NetAddr::IPv4Net.parse(it.ip_address).len > 2 })
  end

  def sorted_ipv4(ip_infos)
    ip_infos.sort_by { NetAddr::IPv4Net.parse(it.ip_address).network.addr }
  end

  def ipv6
    @ip_infos.select { it.ip_address.include?(":") }
      .sort_by { NetAddr::IPv6Net.parse(it.ip_address).network.addr }
  end

  def host_address(ip_info)
    net = NetAddr::IPv6Net.parse(ip_info.ip_address)
    offset = ip_info.gateway ? CONNECTIVITY_HOST_OFFSET : ROUTED_HOST_OFFSET
    "#{net.nth(offset)}/#{net.netmask.prefix_len}"
  end
end
