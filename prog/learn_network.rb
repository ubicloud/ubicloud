# frozen_string_literal: true

require "json"

class Prog::LearnNetwork < Prog::Base
  subject_is :sshable, :vm_host

  label def start
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
