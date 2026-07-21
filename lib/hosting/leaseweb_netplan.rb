# frozen_string_literal: true

require "yaml"

# Builds the desired-state /etc/netplan/01-netcfg.yaml for a Leaseweb host from
# control-plane data alone: the IPs Leaseweb routes to the server, the MACs of
# its public and internal NICs, and the internal NIC's reserved address on the
# private VLAN. Nothing is read back off the host.
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

  # The desired addresses keyed by the interface each belongs to, so the prog can
  # verify every address landed on the NIC the netplan assigned it rather than
  # merely somewhere on the host: the public NIC's, and the internal NIC's
  # reserved address on the private VLAN when the server has a private network.
  def interface_addresses
    interfaces = {@public_interface => public_addresses}
    interfaces[@internal_interface] = internal_addresses if @internal_interface
    interfaces
  end

  # One default route per address family. A segment gateway resolves to the same
  # router as the main gateway, so a second IPv4 default route would only
  # duplicate the next hop.
  def gateways
    [@main.gateway] + ipv6.filter_map(&:gateway)
  end

  private

  # The main IP, the switched-segment IPs, then each IPv4 block routed to the
  # host, then the host's address within each IPv6 prefix.
  def public_addresses
    [@main.ip_address] + (ipv4_segment + ipv4_blocks).map(&:ip_address) + ipv6.map { host_address(it) }
  end

  # The internal NIC's reserved VLAN address. interface_addresses and
  # internal_ethernet ask only when the server has a private network, which
  # always carries this address.
  def internal_addresses
    [@internal_ip]
  end

  # Leaseweb reserves the host a fixed address on the private VLAN and reports it
  # on internal.ip, so declare it rather than lease it: a VLAN whose DHCP is
  # disabled still gets addressed. optional keeps the port out of the
  # `-i <iface>:degraded` list netplan generates for systemd-networkd-wait-online,
  # so a private port whose link never comes up still cannot stall
  # network-online.target on boot.
  def internal_ethernet
    {"addresses" => internal_addresses, "mtu" => INTERNAL_MTU, "optional" => true}
  end

  # dhcp6 off still leaves networkd accepting router advertisements, which would
  # hand the host a default route the moment ours went missing, and a SLAAC
  # address should Leaseweb ever set a prefix's autonomous flag. The addresses
  # and routes below are the whole desired state, so take neither.
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

  # Leaseweb reserves ROUTER1, ROUTER2 and GATEWAY addresses inside a switched
  # segment, so its router is attached to the segment and ARPs for the members
  # rather than routing them to the main IP. The host answers only for what it
  # configures. pull_ips already yields /32s, which keep the segment out of the
  # host's connected routes: the members it does not hold belong to nobody here.
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
