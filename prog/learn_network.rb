# frozen_string_literal: true

require "json"

class Prog::LearnNetwork < Prog::Base
  subject_is :sshable, :vm_host

  # setup_leaseweb_networking passes verify the desired addresses, gateways, and
  # internal ifname through the frame, so verify needs no second API pull.
  frame_accessor :expected_addresses, :expected_gateways, :expected_internal_interface

  label def start
    if vm_host.provider_name == HostProvider::LEASEWEB_PROVIDER_NAME
      hop_setup_leaseweb_networking
    end

    hop_learn_ip6
  end

  # Leaseweb hands a fresh server only its main IP over DHCP, so we configure
  # every other routed address as the whole desired-state netplan.
  label def setup_leaseweb_networking
    api = vm_host.provider.api
    nics = api.pull_network_interfaces
    links = sshable.cmd_json("/usr/sbin/ip -j link")

    public_interface = interface_for(links, nics.public_mac)
    fail "no interface with leaseweb public mac #{nics.public_mac}" unless public_interface

    internal_interface = nil
    if nics.internal_mac
      internal_interface = interface_for(links, nics.internal_mac)
      fail "no interface with leaseweb internal mac #{nics.internal_mac}" unless internal_interface
    end

    # One API snapshot builds the Address rows and the netplan, so the two cannot
    # disagree; prune drops blocks the set lost before the netplan does.
    ip_infos = api.pull_ips
    vm_host.create_addresses(ip_records: ip_infos)
    vm_host.prune_addresses(ip_records: ip_infos)

    netplan = Hosting::LeasewebNetplan.new(public_interface:, internal_interface:, internal_ip: nics.internal_ip, ip_infos:)
    sshable.cmd("sudo host/bin/setup-leaseweb-networking :netplan", netplan: netplan.to_yaml)

    self.expected_addresses = netplan.interface_addresses
    self.expected_gateways = netplan.gateways
    self.expected_internal_interface = internal_interface
    hop_verify_leaseweb_networking
  end

  def interface_for(links, mac)
    links.find { it["address"] == mac }&.fetch("ifname")
  end

  # netplan apply returns before the kernel holds the addresses, so a separate
  # label naps for them without rerunning the apply or the API pulls.
  label def verify_leaseweb_networking
    # Arm before the waits (apply may converge first, so a non-convergence-gated
    # deadline would never arm); target learn_ip6, where the converged path clears it.
    register_deadline("learn_ip6", 5 * 60)

    links = sshable.cmd_json("/usr/sbin/ip -j addr")

    # Check per interface, not the union: an address on the wrong NIC would pass a
    # global check. Exclude the optional internal NIC so a dead port never pages.
    configured = configured_addresses(links)
    nap 1 unless expected_addresses.except(expected_internal_interface).all? { |ifname, addresses| (addresses - configured.fetch(ifname, [])).empty? }

    # netplan apply exits zero even if a gateway is unreachable, so ping each.
    expected_gateways.each do |gateway|
      if gateway.include?(":")
        sshable.cmd("ping6 -c 2 -W 5 :gateway", gateway:)
      else
        sshable.cmd("ping -c 2 -W 5 :gateway", gateway:)
      end
    end

    # A green public path says nothing about the private port; record its state
    # for diagnostics, never page.
    emit_internal_port_state(links) if expected_internal_interface

    hop_learn_ip6
  end

  # Addresses each interface holds, keyed by ifname, so verify checks placement.
  def configured_addresses(links)
    links.to_h do |link|
      [link["ifname"], link.fetch("addr_info", []).map { "#{it["local"]}/#{it["prefixlen"]}" }]
    end
  end

  # Internal port operstate + carrier for diagnostics; absent when it never got
  # carrier to install a link.
  def emit_internal_port_state(links)
    link = links.find { it["ifname"] == expected_internal_interface } || {}
    Clog.emit("leaseweb internal port state", {leaseweb_internal_port: {ifname: expected_internal_interface, operstate: link["operstate"], carrier: link.fetch("flags", []).include?("LOWER_UP")}})
  end

  label def learn_ip6
    ip6 = parse_ip_addr_j(sshable.cmd_json("/usr/sbin/ip -j -6 addr show scope global"))

    # While it would be ideal for NetAddr's IPv6 support to convey
    # both address and prefix information together as `ip` does, it's
    # designed in a more IPv4-centric way where IP addresses and CIDRs
    # tend to be disaggregated.
    #
    # Postgres's "inet" does support this IPv6-style mixture of
    # addresses and prefixlens, the "cidr" type requires masked-out
    # bits to be zero.  NetAddr's IPv6Net type clears low bits beyond
    # the prefix.
    #
    # Maybe we can improve support for inet in a fork later, NetAddr
    # is not a fast moving project, there is room to improve it, but
    # some would be backwards-incompatible.
    if ip6
      vm_host.update(
        ip6: ip6.addr,
        net6: NetAddr::IPv6Net.new(NetAddr.parse_ip(ip6.addr), NetAddr::Mask128.new(ip6.prefixlen)).to_s,
      )
    end
    pop "learned network information"
  end

  Ip6 = Struct.new(:addr, :prefixlen)

  # `ip ... scope global` also lists ULA (fc00::/7) fabric addresses; only
  # 2000::/3 global unicast is the host's routable prefix.
  GLOBAL_UNICAST = NetAddr::IPv6Net.parse("2000::/3").freeze

  def parse_ip_addr_j(s)
    candidates = s.flat_map { it.fetch("addr_info", []) }.filter_map do |info|
      local = info["local"]
      prefixlen = info["prefixlen"]
      next unless local && prefixlen && prefixlen <= 112
      next unless GLOBAL_UNICAST.contains(NetAddr.parse_ip(local))
      Ip6.new(local, prefixlen)
    end

    return if candidates.empty?

    # Prefer the largest network, e.g. a /64 over a /112.
    min_prefixlen = candidates.map(&:prefixlen).min
    largest = candidates.select { it.prefixlen == min_prefixlen }
    fail "found more than one global unique address prefix" if largest.size > 1

    largest.first
  end
end
