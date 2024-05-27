# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "netaddr"
require "json"
require "openssl"
require "base64"
require "uri"
require_relative "vm_path"
require_relative "cloud_hypervisor"
require_relative "storage_volume"

class VmSetup
  Nic = Struct.new(:net6, :net4, :tap, :mac)

  def initialize(vm_name)
    @vm_name = vm_name
  end

  def q_vm
    @q_vm ||= @vm_name.shellescape
  end

  # YAML quoting
  def yq(s)
    require "yaml"
    # I don't see a better way to quote a string meant for embedding
    # in literal YAML other than to generate a full YAML document and
    # then stripping out headers and footers.  Consider the special
    # string "NO" (parses as boolean, unless quoted):
    #
    # > YAML.dump('NO')
    # => "--- 'NO'\n"
    #
    # > YAML.dump('NO')[4..-2]
    # => "'NO'"
    YAML.dump(s, line_width: -1)[4..-2]
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def prep(unix_user, public_key, nics, gua, ip4, local_ip4, max_vcpus, cpu_topology, mem_gib, ndp_needed, storage_params, storage_secrets, swap_size_bytes, pci_devices)
    setup_networking(false, gua, ip4, local_ip4, nics, ndp_needed, multiqueue: max_vcpus > 1)
    cloudinit(unix_user, public_key, nics, swap_size_bytes)
    storage(storage_params, storage_secrets, true)
    hugepages(mem_gib)
    prepare_pci_devices(pci_devices)
    install_systemd_unit(max_vcpus, cpu_topology, mem_gib, storage_params, nics, pci_devices)
  end

  def recreate_unpersisted(gua, ip4, local_ip4, nics, mem_gib, ndp_needed, storage_params, storage_secrets, multiqueue:)
    setup_networking(true, gua, ip4, local_ip4, nics, ndp_needed, multiqueue: multiqueue)
    hugepages(mem_gib)
    storage(storage_params, storage_secrets, false)
  end

  def setup_networking(skip_persisted, gua, ip4, local_ip4, nics, ndp_needed, multiqueue:)
    ip4 = nil if ip4.empty?
    guest_ephemeral, clover_ephemeral = subdivide_network(NetAddr.parse_net(gua))

    if !skip_persisted
      # Write out guest-delegated and clover infrastructure address
      # ranges, designed around non-floating IPv6 networks bound to the
      # host.
      vp.write_guest_ephemeral(guest_ephemeral.to_s)
      vp.write_clover_ephemeral(clover_ephemeral.to_s)

      if ip4
        vm_sub = NetAddr::IPv4Net.parse(ip4)
        vp.write_public_ipv4(vm_sub.to_s)
        unblock_ip4(ip4)
      end
    end

    interfaces(nics, multiqueue)
    setup_veths_6(guest_ephemeral, clover_ephemeral, gua, ndp_needed)
    setup_taps_6(gua, nics)
    routes4(ip4, local_ip4, nics)
    write_nftables_conf(ip4, gua, nics)
    forwarding
  end

  def unblock_ip4(ip4)
    ip_net = NetAddr::IPv4Net.parse(ip4).network.to_s
    filename = "/etc/nftables.d/#{q_vm}.conf"
    temp_filename = "#{filename}.tmp"
    File.open(temp_filename, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX | File::LOCK_NB)
      f.puts(<<-NFTABLES)
#!/usr/sbin/nft -f
add element inet drop_unused_ip_packets allowed_ipv4_addresses { #{ip_net} }
      NFTABLES
      File.rename(temp_filename, filename)
    end

    reload_nftables
  end

  def block_ip4
    FileUtils.rm_f("/etc/nftables.d/#{q_vm}.conf")
    reload_nftables
  end

  def reload_nftables
    r "systemctl reload nftables"
  end

  # Delete all traces of the VM.
  def purge
    block_ip4

    begin
      r "ip netns del #{q_vm}"
    rescue CommandFail => ex
      raise unless /Cannot remove namespace file ".*": No such file or directory/.match?(ex.stderr)
    end

    FileUtils.rm_f(vp.systemd_service)
    FileUtils.rm_f(vp.dnsmasq_service)
    r "systemctl daemon-reload"

    purge_storage
    unmount_hugepages

    begin
      r "deluser --remove-home #{q_vm}"
    rescue CommandFail => ex
      raise unless /The user `.*' does not exist./.match?(ex.stderr)
    end
  end

  def purge_storage
    # prep.json doesn't exist, nothing more to do
    return if !File.exist?(vp.prep_json)

    storage_roots = []

    params = JSON.parse(File.read(vp.prep_json))
    params["storage_volumes"].each { |params|
      volume = StorageVolume.new(@vm_name, params)
      volume.purge_spdk_artifacts
      storage_roots.append(volume.storage_root)
    }

    storage_roots.each { |path|
      rm_if_exists(path)
    }
  end

  def unmount_hugepages
    r "umount #{vp.q_hugepages}"
  rescue CommandFail => ex
    raise unless /(no mount point specified)|(not mounted)|(No such file or directory)/.match?(ex.stderr)
  end

  def hugepages(mem_gib)
    FileUtils.mkdir_p vp.hugepages
    FileUtils.chown @vm_name, @vm_name, vp.hugepages
    r "mount -t hugetlbfs -o uid=#{q_vm},size=#{mem_gib}G nodev #{vp.q_hugepages}"
  end

  def interfaces(nics, multiqueue)
    # We first delete the network namespace for idempotency. Instead
    # we could catch various exceptions for each command run, and if
    # the error message matches certain text, we could resume. But
    # the "ip link add" step generates the MAC addresses randomly,
    # which makes it unsuitable for error message matching. Deleting
    # and recreating the network namespace seems easier and safer.
    begin
      r "ip netns del #{q_vm}"
    rescue CommandFail => ex
      raise unless /Cannot remove namespace file ".*": No such file or directory/.match?(ex.stderr)
    end

    # After the above deletion, the vetho interface may still exist because the
    # namespace deletion does not handle related interface deletion
    # in an atomic way. The command returns success and the cleanup of the
    # vetho* interface may be done a little bit later. Here, we wait for the
    # interface to disappear before going ahead because the ip link add command
    # is not idempotent, either.
    5.times do
      if File.exist?("/sys/class/net/vetho#{q_vm}")
        sleep 0.1
      else
        break
      end
    end

    r "ip netns add #{q_vm}"

    # Generate MAC addresses rather than letting Linux do it to avoid
    # a vexing bug whereby a freshly created link will, at least once,
    # spontaneously change its MAC address sometime soon after
    # creation, as caught by instrumenting reads of
    # /sys/class/net/vethi#{q_vm}/address at two points in time.  The
    # result is a race condition that *sometimes* worked.
    r "ip link add vetho#{q_vm} addr #{gen_mac.shellescape} type veth peer name vethi#{q_vm} addr #{gen_mac.shellescape} netns #{q_vm}"
    multiqueue_fragment = multiqueue ? " multi_queue vnet_hdr " : " "
    nics.each do |nic|
      r "ip -n #{q_vm} tuntap add dev #{nic.tap} mode tap user #{q_vm} #{multiqueue_fragment}"
    end
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    [halved, halved.next_sib]
  end

  def setup_veths_6(guest_ephemeral, clover_ephemeral, gua, ndp_needed)
    # Routing: from host to subordinate.
    vethi_ll = mac_to_ipv6_link_local(r("ip netns exec #{q_vm} cat /sys/class/net/vethi#{q_vm}/address").chomp)
    r "ip link set dev vetho#{q_vm} up"
    r "ip route replace #{gua.shellescape} via #{vethi_ll.shellescape} dev vetho#{q_vm}"

    if ndp_needed
      routes = r "ip -j route"
      main_device = parse_routes(routes)
      r "ip -6 neigh add proxy #{guest_ephemeral.nth(2)} dev #{main_device}"
    end

    # Accept clover traffic within the namespace (don't just let it
    # enter a default routing loop via forwarding)
    r "ip -n #{q_vm} addr replace #{clover_ephemeral.to_s.shellescape} dev vethi#{q_vm}"

    # Routing: from subordinate to host.
    vetho_ll = mac_to_ipv6_link_local(File.read("/sys/class/net/vetho#{q_vm}/address").chomp)
    r "ip -n #{q_vm} link set dev vethi#{q_vm} up"
    r "ip -n #{q_vm} route replace 2000::/3 via #{vetho_ll.shellescape} dev vethi#{q_vm}"
  end

  def setup_taps_6(gua, nics)
    # Write out guest-delegated and clover infrastructure address
    # ranges, designed around non-floating IPv6 networks bound to the
    # host.
    guest_ephemeral, _ = subdivide_network(NetAddr.parse_net(gua))

    # Allocate ::1 in the guest network for DHCPv6.
    guest_intrusion = guest_ephemeral.nth(1).to_s + "/" + guest_ephemeral.netmask.prefix_len.to_s
    nics.each do |nic|
      r "ip -n #{q_vm} addr replace #{guest_intrusion.shellescape} dev #{nic.tap}"

      # Route ephemeral address to tap.
      r "ip -n #{q_vm} link set dev #{nic.tap} up"
      r "ip -n #{q_vm} route replace #{guest_ephemeral.to_s.shellescape} via #{mac_to_ipv6_link_local(nic.mac)} dev #{nic.tap}"

      # Route private subnet addresses to tap.
      ip6 = NetAddr::IPv6Net.parse(nic.net6)

      # Allocate ::1 in the guest network for DHCPv6.
      r "ip -n #{q_vm} addr replace #{ip6.nth(1)}/#{ip6.netmask.prefix_len} dev #{nic.tap}"
      r "ip -n #{q_vm} route replace #{ip6.to_s.shellescape} via #{mac_to_ipv6_link_local(nic.mac)} dev #{nic.tap}"
    end
  end

  def parse_routes(routes)
    routes_j = JSON.parse(routes)
    default_route = routes_j.find { |route| route["dst"] == "default" }
    return default_route["dev"] if default_route

    fail "No default route found in #{routes_j.inspect}"
  end

  def routes4(ip4, ip4_local, nics)
    vm_sub = NetAddr::IPv4Net.parse(ip4) if ip4
    local_ip = NetAddr::IPv4Net.parse(ip4_local)
    vm = vm_sub.to_s if ip4
    vetho, vethi = [local_ip.network.to_s,
      local_ip.next_sib.network.to_s]

    r "ip addr replace #{vetho}/32 dev vetho#{q_vm}"
    r "ip route replace #{vm} dev vetho#{q_vm}" if ip4
    r "echo 1 > /proc/sys/net/ipv4/conf/vetho#{q_vm}/proxy_arp"

    r "ip -n #{q_vm} addr replace #{vethi}/32 dev vethi#{q_vm}"
    # default?
    r "ip -n #{q_vm} route replace #{vetho} dev vethi#{q_vm}"

    nics.each do |nic|
      r "ip -n #{q_vm} route replace #{vm} dev #{nic.tap}" if ip4
      r "ip -n #{q_vm} route replace default via #{vetho} dev vethi#{q_vm}"

      r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/vethi#{q_vm}/proxy_arp'"
      r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/#{nic.tap}/proxy_arp'"
    end
  end

  def write_nftables_conf(ip4, gua, nics)
    config = build_nftables_config(gua, nics, ip4)
    vp.write_nftables_conf(config)
    apply_nftables
  end

  def generate_nat4_rules(ip4, private_ip)
    return unless ip4

    public_ipv4 = NetAddr::IPv4Net.parse(ip4).network.to_s
    private_ipv4 = NetAddr::IPv4Net.parse(private_ip).network.to_s

    <<~NAT4_RULES
    table ip nat {
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr #{public_ipv4} dnat to #{private_ipv4}
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr #{private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{public_ipv4}
        ip saddr #{private_ipv4} ip daddr #{private_ipv4} snat to #{public_ipv4}
      }
    }
    NAT4_RULES
  end

  def generate_ip4_filter_rules(nics, ip4)
    ips = nics.map(&:net4).push(ip4).join(", ")
    macs = nics.map(&:mac).join(", ")
    "ether saddr {#{macs}} ip saddr != {#{ips}} drop"
  end

  def generate_dhcp_filter_rule
    "oifname vethi#{q_vm} udp sport { 67, 68 } udp dport { 67, 68 } drop"
  end

  def generate_ip6_public_filter(nic_first, guest_ephemeral)
    "ether saddr #{nic_first.mac} ip6 saddr != {#{guest_ephemeral},#{nic_first.net6},#{mac_to_ipv6_link_local(nic_first.mac)}} drop"
  end

  def generate_ip6_private_filter_rules(nics)
    nics.map { "ether saddr #{_1.mac} ip6 saddr != #{_1.net6} drop" }.join("\n")
  end

  def build_nftables_config(gua, nics, ip4)
    guest_ephemeral = subdivide_network(NetAddr.parse_net(gua)).first
    <<~NFTABLES_CONF
      table ip raw {
        chain prerouting {
          type filter hook prerouting priority raw; policy accept;
          # allow dhcp
          udp sport 68 udp dport 67 accept
          udp sport 67 udp dport 68 accept

          # avoid ip4 spoofing
          #{generate_ip4_filter_rules(nics, ip4)}
        }
        chain postrouting {
          type filter hook postrouting priority raw; policy accept;
          # avoid dhcp ports to be used for spoofing
          #{generate_dhcp_filter_rule}
        }
      }
      table ip6 raw {
        chain prerouting {
          type filter hook prerouting priority raw; policy accept;
          # avoid ip6 spoofing
          #{generate_ip6_public_filter(nics.first, guest_ephemeral)}
          #{generate_ip6_private_filter_rules(nics[1..])}
        }
      }
      # NAT4 rules
      #{generate_nat4_rules(ip4, nics.first.net4)}
      table inet fw_table {
        chain forward_ingress {
          type filter hook forward priority filter; policy drop;
          ip saddr 0.0.0.0/0 tcp dport 22 ip daddr #{nics.first.net4} ct state established,related,new counter accept
          ip saddr #{nics.first.net4} tcp sport 22 ct state established,related counter accept
        }
      }
    NFTABLES_CONF
  end

  def apply_nftables
    r "ip netns exec #{q_vm} bash -c 'nft flush ruleset'"
    r "ip netns exec #{q_vm} bash -c 'nft -f #{vp.q_nftables_conf}'"
  end

  def cloudinit(unix_user, public_key, nics, swap_size_bytes)
    vp.write_meta_data(<<EOS)
instance-id: #{yq(@vm_name)}
local-hostname: #{yq(@vm_name)}
EOS

    guest_network = NetAddr.parse_net(vp.read_guest_ephemeral)
    private_ip_dhcp = nics.map do |nic|
      vm_sub_6 = NetAddr::IPv6Net.parse(nic.net6)
      vm_sub_4 = NetAddr::IPv4Net.parse(nic.net4)
      <<DHCP
dhcp-range=#{nic.tap},#{vm_sub_4.nth(0)},#{vm_sub_4.nth(0)},#{vm_sub_4.netmask.prefix_len}
dhcp-range=#{nic.tap},#{vm_sub_6.nth(2)},#{vm_sub_6.nth(2)},#{vm_sub_6.netmask.prefix_len}
DHCP
    end.join("\n")

    raparams = nics.map { "ra-param=#{_1.tap}" }.join("\n")

    vp.write_dnsmasq_conf(<<DNSMASQ_CONF)
pid-file=
leasefile-ro
enable-ra
dhcp-authoritative
#{raparams}
dhcp-range=#{guest_network.nth(2)},#{guest_network.nth(2)},#{guest_network.netmask.prefix_len}
#{private_ip_dhcp}
dhcp-option=option6:dns-server,2620:fe::fe,2620:fe::9
dhcp-option=option:dns-server,149.112.112.112,9.9.9.9
dhcp-option=26,1400
DNSMASQ_CONF

    ethernets = nics.map do |nic|
      <<ETHERNETS
  #{yq("enx" + nic.mac.tr(":", "").downcase)}:
    match:
      macaddress: "#{nic.mac}"
    dhcp6: true
    dhcp4: true
ETHERNETS
    end.join("\n")

    vp.write_network_config(<<EOS)
version: 2
ethernets:
#{ethernets}
EOS

    write_user_data(unix_user, public_key, swap_size_bytes)

    FileUtils.rm_rf(vp.cloudinit_img)
    r "mkdosfs -n CIDATA -C #{vp.q_cloudinit_img} 8192"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_user_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_meta_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_network_config} ::"
    FileUtils.chown @vm_name, @vm_name, vp.cloudinit_img
  end

  def generate_swap_config(swap_size_bytes)
    return unless swap_size_bytes
    fail "BUG: swap_size_bytes must be an integer" unless swap_size_bytes.instance_of?(Integer)

    <<~SWAP_CONFIG
    swap:
      filename: /swapfile
      size: #{yq(swap_size_bytes)}
    SWAP_CONFIG
  end

  def write_user_data(unix_user, public_key, swap_size_bytes)
    vp.write_user_data(<<EOS)
#cloud-config
users:
  - name: #{yq(unix_user)}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - #{yq(public_key)}

ssh_pwauth: False

runcmd:
  - [ systemctl, daemon-reload]

#{generate_swap_config(swap_size_bytes)}
EOS
  end

  def storage(storage_params, storage_secrets, prep)
    storage_params.map { |params|
      device_id = params["device_id"]
      key_wrapping_secrets = storage_secrets[device_id]
      storage_volume = StorageVolume.new(@vm_name, params)
      storage_volume.prep(key_wrapping_secrets) if prep
      storage_volume.start(key_wrapping_secrets)
    }
  end

  # Unnecessary if host has this set before creating the netns, but
  # harmless and fast enough to double up.
  def forwarding
    r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.ip_forward=1")
  end

  def prepare_pci_devices(pci_devices)
    pci_devices.select { _1[0].end_with? ".0" }.each do |pci_dev|
      r("echo 1 > /sys/bus/pci/devices/0000:#{pci_dev[0]}/reset")
      r("chown #{@vm_name}:#{@vm_name} /sys/kernel/iommu_groups/#{pci_dev[1]} /dev/vfio/#{pci_dev[1]}")
    end
  end

  def install_systemd_unit(max_vcpus, cpu_topology, mem_gib, storage_params, nics, pci_devices)
    cpu_setting = "boot=#{max_vcpus},topology=#{cpu_topology}"

    tapnames = nics.map { "-i #{_1.tap}" }.join(" ")

    vp.write_dnsmasq_service <<DNSMASQ_SERVICE
[Unit]
Description=A lightweight DHCP and caching DNS server
After=network.target

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
Type=simple
ExecStartPre=/usr/local/sbin/dnsmasq --test
ExecStart=/usr/local/sbin/dnsmasq -k -h -C /vm/#{@vm_name}/dnsmasq.conf --log-debug #{tapnames} --user=#{@vm_name} --group=#{@vm_name}
ExecReload=/bin/kill -HUP $MAINPID
ProtectSystem=strict
PrivateDevices=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectHome=yes
NoNewPrivileges=yes
ReadOnlyPaths=/
DNSMASQ_SERVICE

    storage_volumes = storage_params.map { |params| StorageVolume.new(@vm_name, params) }

    disk_params = storage_volumes.map { |volume|
      "--disk vhost_user=true,socket=#{volume.vhost_sock},num_queues=1,queue_size=256 \\"
    }

    spdk_services = storage_volumes.map { |volume| volume.spdk_service }.uniq
    spdk_after = spdk_services.map { |s| "After=#{s}" }.join("\n")
    spdk_requires = spdk_services.map { |s| "Requires=#{s}" }.join("\n")

    net_params = nics.map { "--net mac=#{_1.mac},tap=#{_1.tap},ip=,mask=,num_queues=#{max_vcpus * 2 + 1}" }
    pci_device_params = pci_devices.map { " --device path=/sys/bus/pci/devices/0000:#{_1[0]}/" }.join
    limit_memlock = pci_devices.empty? ? "" : "LimitMEMLOCK=#{mem_gib * 1073741824}"

    # YYY: Do something about systemd escaping, i.e. research the
    # rules and write a routine for it.  Banning suspicious strings
    # from VmPath is also a good idea.
    fail "BUG" if /["'\s]/.match?(cpu_setting)
    vp.write_systemd_service <<SERVICE
[Unit]
Description=#{@vm_name}
After=network.target
#{spdk_after}
After=#{@vm_name}-dnsmasq.service
#{spdk_requires}
Requires=#{@vm_name}-dnsmasq.service

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
ExecStartPre=/usr/bin/rm -f #{vp.ch_api_sock}

ExecStart=#{CloudHypervisor::VERSION.bin} -v \
--api-socket path=#{vp.ch_api_sock} \
--kernel #{CloudHypervisor::NEW_FIRMWARE.path} \
#{disk_params.join("\n")}
--disk path=#{vp.cloudinit_img} \
--console off --serial file=#{vp.serial_log} \
--cpus #{cpu_setting} \
--memory size=#{mem_gib}G,hugepages=on,hugepage_size=1G \
#{pci_device_params} \
#{net_params.join(" \\\n")}

ExecStop=#{CloudHypervisor::VERSION.ch_remote_bin} --api-socket #{vp.ch_api_sock} shutdown-vmm
Restart=no
User=#{@vm_name}
Group=#{@vm_name}

LimitNOFILE=500000
#{limit_memlock}
SERVICE
    r "systemctl daemon-reload"
  end

  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here is not a formality: otherwise assigning a ipv6 link
  # local address errors out.
  def gen_mac
    ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
      "%0.2X" % _1
    }.join(":").downcase
  end

  # By reading the mac address from an interface, compute its ipv6
  # link local address that it would have if its device state were set
  # to up.
  def mac_to_ipv6_link_local(mac)
    eui = mac.split(":").map(&:hex)
    eui.insert(3, 0xff, 0xfe)
    eui[0] ^= 0x02

    "fe80::" + eui.each_slice(2).map { |pair|
      pair.map { format("%02x", _1) }.join
    }.join(":")
  end
end
