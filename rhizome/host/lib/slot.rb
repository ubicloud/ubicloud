# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "ember_config"
require "fileutils"
require "netaddr"

class Slot
  attr_reader :index, :name, :public_ip6

  def initialize(index, ip6_block: nil)
    @index = index
    @name = EmberConfig.slot_name(index)
    @ip6_block = ip6_block
    @public_ip6 = ip6_block && self.class.slot_address(ip6_block, index)
  end

  def self.slot_address(ip6_block, index)
    NetAddr::IPv6Net.parse(ip6_block).nth(index + 2).to_s
  end

  def dir = EmberConfig.slot_dir(@index)

  def uid = 60_000 + @index

  def netns = @name

  def veth_host = "emo#{@index}"

  def veth_ns = "emi#{@index}"

  def link_host_ip6 = "fd00:b1c:ffff:#{@index.to_s(16)}::1"

  def link_ns_ip6 = "fd00:b1c:ffff:#{@index.to_s(16)}::2"

  def exists? = File.exist?("/var/run/netns/#{netns}")

  def ns(*cmd) = r("ip", "netns", "exec", netns, *cmd)

  def create
    create_user
    destroy_network if exists?

    r("ip", "netns", "add", netns)
    r("ip", "link", "add", veth_host, "type", "veth", "peer", "name", veth_ns)
    r("ip", "link", "set", veth_ns, "netns", netns)
    r("ip", "addr", "add", "#{link_host_ip6}/64", "dev", veth_host, "nodad")
    r("ip", "link", "set", veth_host, "up")

    ns("ip", "link", "set", "lo", "up")
    ns("sysctl", "-q", "-w", "net.ipv6.conf.all.forwarding=1")
    ns("sysctl", "-q", "-w", "net.ipv6.conf.all.accept_ra=0")
    ns("ip", "addr", "add", "#{link_ns_ip6}/64", "dev", veth_ns, "nodad")
    ns("ip", "link", "set", veth_ns, "up")

    ns("ip", "tuntap", "add", "dev", "cltap", "mode", "tap", "user", uid.to_s)
    ns("ip", "addr", "add", "#{EmberConfig::GUEST_ROUTER_IP6}/64", "dev", "cltap", "nodad")
    ns("ip", "addr", "add", "#{EmberConfig::GUEST_ROUTER_IP4}/30", "dev", "cltap")
    ns("ip", "link", "set", "cltap", "up")
    ns("ip", "-6", "route", "add", "default", "via", link_host_ip6, "dev", veth_ns)

    r("ip", "-6", "route", "replace", "#{@public_ip6}/128", "via", link_ns_ip6, "dev", veth_host)
    apply_nftables([])

    FileUtils.mkdir_p(dir)
    FileUtils.chown_R(@name, @name, dir)
  end

  def create_user
    return if user_exists?
    r("useradd", "--uid", uid.to_s, "--no-create-home", "--home-dir", dir,
      "--shell", "/usr/sbin/nologin", "--groups", "kvm", @name)
  end

  def user_exists?
    r("id", "-u", @name)
    true
  rescue CommandFail
    false
  end

  def apply_nftables(ingress_sources)
    elements = ingress_sources.empty? ? "" : "elements = { #{ingress_sources.join(", ")} }"
    ruleset = <<~NFT
      table inet ember
      delete table inet ember
      table inet ember {
        set ingress_v6 {
          type ipv6_addr
          flags interval
          #{elements}
        }
        chain prerouting { type nat hook prerouting priority dstnat; policy accept;
          ip6 daddr #{@public_ip6} dnat ip6 to #{EmberConfig::GUEST_IP6}
        }
        chain forward { type filter hook forward priority filter; policy drop;
          ct state established,related accept
          iifname "#{veth_ns}" oifname "cltap" ip6 saddr @ingress_v6 ip6 daddr #{EmberConfig::GUEST_IP6} meta l4proto tcp ct state new accept
          iifname "#{veth_ns}" oifname "cltap" ip6 saddr #{link_host_ip6} ip6 daddr #{EmberConfig::GUEST_IP6} meta l4proto tcp ct state new accept
          iifname "cltap" drop
        }
        chain raw_pre { type filter hook prerouting priority raw; policy accept;
          iifname "cltap" ether saddr != #{EmberConfig::GUEST_MAC} drop
          iifname "cltap" ip6 saddr != #{EmberConfig::GUEST_IP6} ip6 saddr != fe80::/64 drop
        }
        chain input { type filter hook input priority filter; policy drop;
          ct state established,related accept
          icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept
          iifname "lo" accept
          iifname "#{veth_ns}" accept
        }
      }
    NFT
    r("ip", "netns", "exec", netns, "nft", "-f", "-", stdin: ruleset)
  end

  def destroy_network
    r("ip", "netns", "del", netns)
    r("ip", "link", "del", veth_host)
  rescue CommandFail
    nil
  end
end
