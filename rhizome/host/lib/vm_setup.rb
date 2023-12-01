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

  def prep(unix_user, public_key, nics, gua, ip4, local_ip4, boot_image, max_vcpus, cpu_topology, mem_gib, ndp_needed, storage_volumes, storage_secrets)
    setup_networking(false, gua, ip4, local_ip4, nics, ndp_needed)
    cloudinit(unix_user, public_key, nics)
    download_boot_image(boot_image)
    storage_params = storage(storage_volumes, storage_secrets, true)
    hugepages(mem_gib)
    install_systemd_unit(max_vcpus, cpu_topology, mem_gib, storage_params, nics)
  end

  def recreate_unpersisted(gua, ip4, local_ip4, nics, mem_gib, ndp_needed, storage_params, storage_secrets)
    setup_networking(true, gua, ip4, local_ip4, nics, ndp_needed)
    hugepages(mem_gib)
    storage(storage_params, storage_secrets, false)
  end

  def setup_networking(skip_persisted, gua, ip4, local_ip4, nics, ndp_needed)
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
      end
    end

    interfaces(nics)
    setup_veths_6(guest_ephemeral, clover_ephemeral, gua, ndp_needed)
    setup_taps_6(gua, nics)
    routes4(ip4, local_ip4, nics)
    write_nftables_conf(ip4, gua, nics)
    forwarding
  end

  # Delete all traces of the VM.
  def purge
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
    # Storage hasn't been created yet, so nothing to purge.
    return if !File.exist?(vp.storage_root)

    params = JSON.parse(File.read(vp.prep_json))
    params["storage_volumes"].each { |params|
      volume = StorageVolume.new(@vm_name, params)
      volume.purge_spdk_artifacts
    }

    rm_if_exists(vp.storage_root)
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

  def interfaces(nics)
    r "ip netns add #{q_vm}"

    # Generate MAC addresses rather than letting Linux do it to avoid
    # a vexing bug whereby a freshly created link will, at least once,
    # spontaneously change its MAC address sometime soon after
    # creation, as caught by instrumenting reads of
    # /sys/class/net/vethi#{q_vm}/address at two points in time.  The
    # result is a race condition that *sometimes* worked.
    r "ip link add vetho#{q_vm} addr #{gen_mac.shellescape} type veth peer name vethi#{q_vm} addr #{gen_mac.shellescape} netns #{q_vm}"
    nics.each do |nic|
      r "ip -n #{q_vm} tuntap add dev #{nic.tap} mode tap user #{q_vm}"
    end
  rescue CommandFail => ex
    errors = [
      /ioctl(TUNSETIFF): Device or resource busy/,
      /File exists/
    ]
    raise unless errors.any? { |e| e.match?(ex.stderr) }
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
      }
    }
    NAT4_RULES
  end

  def generate_ip4_filter_rules(nics)
    nics.map { "ether saddr #{_1.mac} ip saddr != #{_1.net4} drop" }.join("\n")
  end

  def generate_private_ip4_list(nics)
    nics.map { NetAddr::IPv4Net.parse(_1.net4).network.to_s + "/26" }.join(",")
  end

  def generate_private_ip6_list(nics)
    nics.map { NetAddr::IPv6Net.parse(_1.net6).network.to_s + "/64" }.join(",")
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
          #{generate_ip4_filter_rules(nics)}
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
        set allowed_ipv4_ips {
          type ipv4_addr;
          flags interval;
        }
      
        set allowed_ipv6_ips {
          type ipv6_addr;
          flags interval;
        }

        set private_ipv4_ips {
          type ipv4_addr;
          flags interval;
          elements = {
            #{generate_private_ip4_list(nics)}
          }
        }

        set private_ipv6_ips {
          type ipv6_addr
          flags interval
          elements = { #{generate_private_ip6_list(nics)} }
        }

        chain forward_ingress {
          type filter hook forward priority filter; policy drop;
          tcp dport 22 ct state new,established,related accept
          ip saddr @private_ipv4_ips ct state established,related,new counter accept
          ip daddr @private_ipv4_ips ct state established,related counter accept
          ip6 saddr @private_ipv6_ips ct state established,related,new counter accept
          ip6 daddr @private_ipv6_ips ct state established,related counter accept
          ip6 saddr #{guest_ephemeral} ct state established,related,new counter accept
          ip6 daddr #{guest_ephemeral} ct state established,related counter accept
          ip saddr @allowed_ipv4_ips ip daddr @private_ipv4_ips counter accept
          ip6 saddr @allowed_ipv6_ips ip6 daddr #{guest_ephemeral} counter accept
        }
      }
    NFTABLES_CONF
  end

  def apply_nftables
    r "ip netns exec #{q_vm} bash -c 'nft flush ruleset'"
    r "ip netns exec #{q_vm} bash -c 'nft -f #{vp.q_nftables_conf}'"
  end

  def cloudinit(unix_user, public_key, nics)
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

    write_user_data(unix_user, public_key)

    FileUtils.rm_rf(vp.cloudinit_img)
    r "mkdosfs -n CIDATA -C #{vp.q_cloudinit_img} 8192"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_user_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_meta_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_network_config} ::"
    FileUtils.chown @vm_name, @vm_name, vp.cloudinit_img
  end

  def write_user_data(unix_user, public_key)
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
EOS
  end

  def storage(storage_params, storage_secrets, prep)
    storage_params.map { |params|
      device_id = params["device_id"]
      key_wrapping_secrets = storage_secrets[device_id]
      storage_volume = StorageVolume.new(@vm_name, params)
      storage_volume.prep(key_wrapping_secrets) if prep
      storage_volume.start(key_wrapping_secrets)
      {
        vhost_sock: storage_volume.vhost_sock,
        spdk_service: storage_volume.spdk_service
      }
    }
  end

  def download_boot_image(boot_image, custom_url: nil)
    urls = {
      "ubuntu-jammy" => "https://cloud-images.ubuntu.com/jammy/20231010/jammy-server-cloudimg-#{Arch.render(x64: "amd64")}.img",
      "almalinux-9.1" => Arch.render(x64: "x86_64", arm64: "aarch64").yield_self { "https://repo.almalinux.org/almalinux/9/cloud/#{_1}/images/AlmaLinux-9-GenericCloud-latest.#{_1}.qcow2" },
      "github-ubuntu-2204" => nil,
      "github-ubuntu-2004" => nil
    }

    download = urls.fetch(boot_image) || custom_url
    image_path = vp.image_path(boot_image)
    unless File.exist?(image_path)
      fail "Must provide custom_url for #{boot_image} image" if download.nil?
      FileUtils.mkdir_p vp.image_root

      # If image URL has query parameter such as SAS token, File.extname returns
      # it too. We need to remove them and only get extension.
      image_ext = File.extname(URI.parse(download).path)
      initial_format = case image_ext
      when ".qcow2", ".img"
        "qcow2"
      when ".vhd"
        "vpc"
      else
        fail "Unsupported boot_image format: #{image_ext}"
      end

      # Use of File::EXCL provokes a crash rather than a race
      # condition if two VMs are lazily getting their images at the
      # same time.
      temp_path = "/tmp/" + boot_image + image_ext + ".tmp"
      File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
        if download.match?(/^https:\/\/.+\.blob\.core\.windows\.net/)
          install_azcopy
          r "AZCOPY_CONCURRENCY_VALUE=5 azcopy copy #{download.shellescape} #{temp_path.shellescape}"
        else
          r "curl -L10 -o #{temp_path.shellescape} #{download.shellescape}"
        end
      end

      # Images are presumed to be atomically renamed into the path,
      # i.e. no partial images will be passed to qemu-image.
      r "qemu-img convert -p -f #{initial_format.shellescape} -O raw #{temp_path.shellescape} #{image_path.shellescape}"

      rm_if_exists(temp_path)
    end
  end

  def install_azcopy
    r "which azcopy"
  rescue CommandFail
    r "curl -L10 -o azcopy_v10.tar.gz 'https://aka.ms/downloadazcopy-v10-linux#{Arch.render(x64: "", arm64: "-arm64")}'"
    r "tar --strip-components=1 --exclude=*.txt -xzvf azcopy_v10.tar.gz"
    r "rm azcopy_v10.tar.gz"
    r "mv azcopy /usr/bin/azcopy"
    r "chmod +x /usr/bin/azcopy"
  end

  # Unnecessary if host has this set before creating the netns, but
  # harmless and fast enough to double up.
  def forwarding
    r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.ip_forward=1")
  end

  def install_systemd_unit(max_vcpus, cpu_topology, mem_gib, storage_info, nics)
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

    disk_params = storage_info.map { |info|
      "--disk vhost_user=true,socket=#{info[:vhost_sock]},num_queues=1,queue_size=256 \\"
    }

    spdk_services = storage_info.map { |info| info[:spdk_service] }.uniq
    spdk_after = spdk_services.map { |s| "After=#{s}" }.join("\n")
    spdk_requires = spdk_services.map { |s| "Requires=#{s}" }.join("\n")

    net_params = nics.map { "--net mac=#{_1.mac},tap=#{_1.tap},ip=,mask=" }

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
--kernel #{CloudHypervisor::FIRMWARE.path} \
#{disk_params.join("\n")}
--disk path=#{vp.cloudinit_img} \
--console off --serial file=#{vp.serial_log} \
--cpus #{cpu_setting} \
--memory size=#{mem_gib}G,hugepages=on,hugepage_size=1G \
#{net_params.join(" \\\n")}

ExecStop=#{CloudHypervisor::VERSION.ch_remote_bin} --api-socket #{vp.ch_api_sock} shutdown-vmm
Restart=no
User=#{@vm_name}
Group=#{@vm_name}
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
