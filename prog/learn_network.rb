# frozen_string_literal: true

require "json"

class Prog::LearnNetwork < Prog::Base
  subject_is :sshable, :vm_host

  # setup_leaseweb_networking hands verify_leaseweb_networking the desired
  # addresses keyed by interface, the gateways, and the internal ifname through
  # the frame, so verification confirms the host converged on the same snapshot
  # the netplan and Address rows were built from, without a third Leaseweb API
  # pull that could disagree with it. The internal ifname names the optional port
  # verify tolerates rather than waits on.
  frame_accessor :expected_addresses, :expected_gateways, :expected_internal_interface

  label def start
    if vm_host.provider_name == HostProvider::LEASEWEB_PROVIDER_NAME
      hop_setup_leaseweb_networking
    end

    hop_learn_ip6
  end

  # Leaseweb hands a fresh server only its main IP over DHCP; every other
  # address it routes to the server has to be configured by us. Write the whole
  # desired-state netplan rather than patching what the image happened to ship.
  label def setup_leaseweb_networking
    api = vm_host.provider.api
    nics = api.pull_network_interfaces
    links = sshable.cmd_json("/usr/sbin/ip -j link")

    public_interface = interface_for(links, nics.public_mac)
    fail "no interface with leaseweb public mac #{nics.public_mac}" unless public_interface

    # An internal mac means the server has a private network, so a port we cannot
    # find is a misconfigured host rather than a server without private networking.
    internal_interface = nil
    if nics.internal_mac
      internal_interface = interface_for(links, nics.internal_mac)
      fail "no interface with leaseweb internal mac #{nics.internal_mac}" unless internal_interface
    end

    # One API snapshot builds both the Address rows and the netplan, so the host
    # can never hold an address the control plane failed to record. create_addresses
    # skips the rows assemble already made and adds any the set has gained since;
    # prune_addresses drops any the set has lost, before the netplan does the same,
    # so the control plane never routes a VM to a block the host stopped carrying.
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

  # `netplan apply` returns once networkd has taken the config, not once the
  # kernel holds what it asks for: one run on 91478 gained the addresses 64ms
  # after the script exited. A separate label naps for them to land so a slow
  # apply never reruns the netplan write or the API pulls that precede it, and
  # the deadline pages instead of an attempt counter swallowing the failure.
  label def verify_leaseweb_networking
    # Arm the page deadline before both the convergence wait and the gateway
    # pings: `netplan apply` often lands every address before the first entry
    # here, so a deadline gated on non-convergence would never arm on that path,
    # and an unreachable gateway would then retry forever without paging. A strand
    # clears a deadline only on reaching its target label and this prog has no
    # "wait" steady state, so target learn_ip6, the label the converged path hops
    # to; a slow-but-successful run clears it there rather than paging.
    register_deadline("learn_ip6", 5 * 60)

    links = sshable.cmd_json("/usr/sbin/ip -j addr")

    # Compare per interface rather than against the union of every address the
    # host holds: an address the netplan assigned to one NIC that instead landed
    # on another would satisfy a global membership check while leaving the host
    # unconverged on the desired shape. The internal NIC is optional:true, so
    # exclude it: a dead private port must converge verify on the public path
    # alone and never page, and its static /27 may land whenever carrier does.
    configured = configured_addresses(links)
    nap 1 unless expected_addresses.except(expected_internal_interface).all? { |ifname, addresses| (addresses - configured.fetch(ifname, [])).empty? }

    # `netplan apply` exits zero whether or not a gateway answers, so confirm the
    # host can reach each one now that it holds every address.
    expected_gateways.each do |gateway|
      if gateway.include?(":")
        sshable.cmd("ping6 -c 2 -W 5 :gateway", gateway:)
      else
        sshable.cmd("ping -c 2 -W 5 :gateway", gateway:)
      end
    end

    # A green public path says nothing about the private port: its static /27
    # survives carrier loss and it has no gateway to reach, so a port that came
    # up, took the address, then dropped still reads present. Record its state for
    # diagnostics under the tolerate policy; a down internal port is never paged.
    emit_internal_port_state(links) if expected_internal_interface

    hop_learn_ip6
  end

  # `ip -j addr` reduced to the addresses each interface holds, keyed by ifname,
  # so verify can check placement rather than mere presence somewhere on the host.
  def configured_addresses(links)
    links.to_h do |link|
      [link["ifname"], link.fetch("addr_info", []).map { "#{it["local"]}/#{it["prefixlen"]}" }]
    end
  end

  # operstate and the carrier (LOWER_UP) flag for the internal ifname, read from
  # the same `ip -j addr` the address check parsed; the port is absent here when
  # it never gained carrier to install a link. Recorded, never asserted: the
  # private port is optional, so a dead one is observed and pages nothing.
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
