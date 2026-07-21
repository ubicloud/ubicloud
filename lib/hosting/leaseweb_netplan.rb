# frozen_string_literal: true

require "yaml"

# Builds the desired-state /etc/netplan/01-netcfg.yaml for a Leaseweb host from
# control-plane data alone; nothing is read back off the host.
class Hosting::LeasewebNetplan
  # Leaseweb's resolvers and search domain for dedicated servers.
  NAMESERVERS = %w[23.19.53.53 23.19.52.52].freeze
  SEARCH_DOMAINS = %w[dedi.leaseweb.net].freeze

  ROUTE_METRIC = 100
  INTERNAL_MTU = 9000

  # The host claims ::2 out of a connectivity prefix, whose gateway lives
  # outside it in the parent block, and ::1 out of a prefix routed to it.
  CONNECTIVITY_HOST_OFFSET = 2
  ROUTED_HOST_OFFSET = 1

  def initialize(public_interface:, internal_interface:, internal_ip:, ip_infos:)
    @public_interface = public_interface
    @internal_interface = internal_interface
    @internal_ip = internal_ip
    @ip_infos = ip_infos
    @main = ip_infos.find { it.ip_address == "#{it.source_host_ip}/32" }
    fail "no main IPv4 address among leaseweb ip infos" unless @main
  end

  def to_yaml
    YAML.dump(to_h)
  end

  def to_h
    ethernets = {@public_interface => public_ethernet}
    ethernets[@internal_interface] = internal_ethernet if @internal_interface

    {"network" => {"version" => 2, "renderer" => "networkd", "ethernets" => ethernets}}
  end

  # Desired addresses keyed by the interface each belongs to, so verify can check
  # placement, not mere presence.
  def interface_addresses
    interfaces = {@public_interface => public_addresses}
    interfaces[@internal_interface] = internal_addresses if @internal_interface
    interfaces
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
    {"addresses" => internal_addresses, "mtu" => INTERNAL_MTU, "optional" => true}
  end

  # accept-ra false: dhcp6 off still accepts router advertisements, which would
  # add a competing default route / SLAAC address; this file is the whole state.
  def public_ethernet
    {
      "dhcp4" => false,
      "dhcp6" => false,
      "accept-ra" => false,
      "addresses" => public_addresses,
      "routes" => routes,
      "nameservers" => {"search" => SEARCH_DOMAINS, "addresses" => NAMESERVERS},
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

  def ipv4_blocks
    sorted_ipv4(ipv4.reject(&:gateway))
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
