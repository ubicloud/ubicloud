# frozen_string_literal: true

class Prog::Leaseweb::SetupNetworking < Prog::Base
  subject_is :sshable, :vm_host

  # start passes verify the desired addresses, gateways, and internal mac
  # through the frame, so verify needs no second API pull.
  frame_accessor :expected_addresses, :expected_gateways, :expected_internal_mac

  # Leaseweb hands a fresh server only its main IP over DHCP, so we configure
  # every other routed address as the whole desired-state netplan.
  label def start
    api = vm_host.provider.api
    nics = api.pull_network_interfaces
    links = sshable.cmd_json("/usr/sbin/ip -j link")

    fail "no interface with leaseweb public mac #{nics.public_mac}" unless interface_for(links, nics.public_mac)
    fail "no interface with leaseweb internal mac #{nics.internal_mac}" if nics.internal_mac && !interface_for(links, nics.internal_mac)

    # /etc/resolv.conf names only the local stub; this file holds the real
    # upstreams the environment handed the host, frozen in since dhcp4 goes off.
    resolv_conf = sshable.cmd("cat /run/systemd/resolve/resolv.conf")
    nameservers = resolv_conf.scan(/^nameserver (\S+)/).flatten.uniq
    fail "no upstream resolvers on the host" if nameservers.empty?
    search_domains = resolv_conf.scan(/^search (.+)/).flatten.flat_map(&:split).uniq

    # The same snapshot records the Address rows and builds the netplan, so a
    # block added since assemble reaches both.
    ip_infos = api.pull_ips
    vm_host.create_addresses(ip_records: ip_infos)

    netplan = Hosting::LeasewebNetplan.new(public_mac: nics.public_mac, internal_mac: nics.internal_mac, internal_ip: nics.internal_ip, ip_infos:, nameservers:, search_domains:)
    sshable.cmd("sudo host/bin/setup-leaseweb-networking :netplan", netplan: netplan.to_yaml)

    self.expected_addresses = netplan.addresses_by_mac
    self.expected_gateways = netplan.gateways
    self.expected_internal_mac = nics.internal_mac
    hop_verify
  end

  def interface_for(links, mac)
    links.find { it["address"] == mac }&.fetch("ifname")
  end

  # netplan apply returns before the kernel holds the addresses, so a separate
  # label naps for them without rerunning the apply or the API pulls.
  label def verify
    links = sshable.cmd_json("/usr/sbin/ip -j addr")

    # Check per interface, not the union: an address on the wrong NIC would pass a
    # global check. Exclude the optional internal NIC so a dead port never pages.
    configured = configured_addresses(links)
    nap 1 unless expected_addresses.except(expected_internal_mac).all? { |mac, addresses| (addresses - configured.fetch(mac, [])).empty? }

    # netplan apply exits zero even if a gateway is unreachable, so ping each.
    expected_gateways.each do |gateway|
      if gateway.include?(":")
        sshable.cmd("sudo ping6 -c 2 -W 5 :gateway", gateway:)
      else
        sshable.cmd("sudo ping -c 2 -W 5 :gateway", gateway:)
      end
    end

    # A green public path says nothing about the private port; record its state
    # for diagnostics, never page.
    emit_internal_port_state(links) if expected_internal_mac

    hop_refresh_nftables
  end

  # The SetupNftables strand prep buds is not ordered against this one, so a
  # block this snapshot added may have missed it. Rerun against the final
  # address set; the run is a full-state rewrite, safe to repeat.
  label def refresh_nftables
    pop "leaseweb networking configured" if retval&.dig("msg") == "nftables was setup"
    push Prog::SetupNftables
  end

  # Addresses each interface holds, keyed by mac, so verify checks placement.
  def configured_addresses(links)
    links.to_h do |link|
      [link["address"], link.fetch("addr_info", []).map { "#{it["local"]}/#{it["prefixlen"]}" }]
    end
  end

  # Internal port operstate + carrier for diagnostics; absent when it never got
  # carrier to install a link.
  def emit_internal_port_state(links)
    link = links.find { it["address"] == expected_internal_mac } || {}
    Clog.emit("leaseweb internal port state", {leaseweb_internal_port: {mac: expected_internal_mac, ifname: link["ifname"], operstate: link["operstate"], carrier: link.fetch("flags", []).include?("LOWER_UP")}})
  end
end
