# frozen_string_literal: true

require "json"

class Prog::LearnNetwork < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    ip6 = parse_ip_addr_j(sshable.cmd("/usr/sbin/ip -j -6 addr show scope global"))

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
    vm_host.update(
      ip6: ip6.addr,
      net6: NetAddr::IPv6Net.new(NetAddr.parse_ip(ip6.addr), NetAddr::Mask128.new(ip6.prefixlen)).to_s
    )
    pop "learned network information"
  end

  Ip6 = Struct.new(:addr, :prefixlen)

  def parse_ip_addr_j(s)
    case JSON.parse(s)
    in [iface]
      case iface.fetch("addr_info").filter_map { |info|
             if (local = info["local"]) && (prefixlen = info["prefixlen"]) && prefixlen <= 64
               Ip6.new(local, prefixlen)
             end
           }
      in [net6]
        net6
      else
        fail "only one global unique address prefix supported on interface"
      end
    else
      fail "only one one interface supported"
    end
  end
end
