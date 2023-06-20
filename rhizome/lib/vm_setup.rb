#!/bin/env ruby
# frozen_string_literal: true

require_relative "common"

require "fileutils"
require "netaddr"
require_relative "vm_path"
require_relative "cloud_hypervisor"
require_relative "spdk"
require "json"

class VmSetup
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

  def prep(unix_user, public_key, private_subnets, gua, ip4, local_ip4, boot_image, max_vcpus, cpu_topology, mem_gib, ndp_needed, storage_volumes)
    ip4 = nil if ip4.empty?
    interfaces
    routes6(gua, private_subnets, ndp_needed)
    routes4(ip4, local_ip4)
    cloudinit(unix_user, public_key, private_subnets, ip4)
    vhost_sockets = storage(storage_volumes, boot_image)
    hugepages(mem_gib)
    install_systemd_unit(max_vcpus, cpu_topology, mem_gib, vhost_sockets)
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

    begin
      r "deluser --remove-home #{q_vm}"
    rescue CommandFail => ex
      raise unless /The user `.*' does not exist./.match?(ex.stderr)
    end
  end

  def hugepages(mem_gib)
    r "mkdir #{vp.q_hugepages}"
    r "mount -t hugetlbfs -o uid=#{q_vm},size=#{mem_gib}G nodev #{vp.q_hugepages}"
    r "chown -R #{q_vm} #{vp.q_hugepages}"
  end

  def interfaces
    r "ip netns add #{q_vm}"

    # Generate MAC addresses rather than letting Linux do it to avoid
    # a vexing bug whereby a freshly created link will, at least once,
    # spontaneously change its MAC address sometime soon after
    # creation, as caught by instrumenting reads of
    # /sys/class/net/vethi#{q_vm}/address at two points in time.  The
    # result is a race condition that *sometimes* worked.
    r "ip link add vetho#{q_vm} addr #{gen_mac.shellescape} type veth peer name vethi#{q_vm} addr #{gen_mac.shellescape} netns #{q_vm}"
    r "ip -n #{q_vm} tuntap add dev tap#{q_vm} mode tap user #{q_vm}"
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

  def routes6(gua, private_subnets, ndp_needed)
    # Routing: from host to subordinate.
    vethi_ll = mac_to_ipv6_link_local(r("ip netns exec #{q_vm} cat /sys/class/net/vethi#{q_vm}/address").chomp)
    r "ip link set dev vetho#{q_vm} up"
    r "ip route add #{gua.shellescape} via #{vethi_ll.shellescape} dev vetho#{q_vm}"

    # Write out guest-delegated and clover infrastructure address
    # ranges, designed around non-floating IPv6 networks bound to the
    # host.
    guest_ephemeral, clover_ephemeral = subdivide_network(NetAddr.parse_net(gua))

    if ndp_needed
      routes = r "ip -j route"
      main_device = parse_routes(routes)
      r "ip -6 neigh add proxy #{guest_ephemeral.nth(2)} dev #{main_device}"
    end

    # Accept clover traffic within the namespace (don't just let it
    # enter a default routing loop via forwarding)
    r "ip -n #{q_vm} addr add #{clover_ephemeral.to_s.shellescape} dev vethi#{q_vm}"

    # Allocate ::1 in the guest network for DHCPv6.
    guest_intrusion = guest_ephemeral.nth(1).to_s + "/" + guest_ephemeral.netmask.prefix_len.to_s
    r "ip -n #{q_vm} addr add #{guest_intrusion.shellescape} dev tap#{q_vm}"

    # Routing: from subordinate to host.
    vetho_ll = mac_to_ipv6_link_local(File.read("/sys/class/net/vetho#{q_vm}/address").chomp)
    r "ip -n #{q_vm} link set dev vethi#{q_vm} up"
    r "ip -n #{q_vm} route add 2000::/3 via #{vetho_ll.shellescape} dev vethi#{q_vm}"

    vp.write_guest_ephemeral(guest_ephemeral.to_s)
    vp.write_clover_ephemeral(clover_ephemeral.to_s)

    # Route ephemeral address to tap.
    r "ip -n #{q_vm} link set dev tap#{q_vm} up"
    r "ip -n #{q_vm} route add #{guest_ephemeral.to_s.shellescape} via #{mac_to_ipv6_link_local(guest_mac)} dev tap#{q_vm}"

    # Route private subnet addresses to tap.
    private_subnets.each do
      r "ip -n #{q_vm} route add #{_1.shellescape} via #{mac_to_ipv6_link_local(guest_mac)} dev tap#{q_vm}"
    end
  end

  def parse_routes(routes)
    routes_j = JSON.parse(routes)
    default_route = routes_j.find { |route| route["dst"] == "default" }
    return default_route["dev"] if default_route

    fail "No default route found in #{routes_j.inspect}"
  end

  def routes4(ip4, ip4_local)
    return unless ip4
    vm_sub = NetAddr::IPv4Net.parse(ip4)
    local_ip = NetAddr::IPv4Net.parse(ip4_local)
    vm, vetho, vethi = [vm_sub.to_s,
      local_ip.network.to_s,
      local_ip.next_sib.network.to_s]

    r "ip addr add #{vetho}/32 dev vetho#{q_vm}"
    r "ip route add #{vm} dev vetho#{q_vm}"
    r "echo 1 > /proc/sys/net/ipv4/conf/vetho#{q_vm}/proxy_arp"

    r "ip -n #{q_vm} addr add #{vethi}/32 dev vethi#{q_vm}"
    r "ip -n #{q_vm} addr add #{vm} dev tap#{q_vm}"
    r "ip -n #{q_vm} route add #{vetho} dev vethi#{q_vm}"
    r "ip -n #{q_vm} route add default via #{vetho} dev vethi#{q_vm}"
    r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/vethi#{q_vm}/proxy_arp'"
    r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/tap#{q_vm}/proxy_arp'"
  end

  def cloudinit(unix_user, public_key, private_subnets, ip4)
    vm_sub = NetAddr::IPv4Net.parse(ip4) if ip4
    vp.write_meta_data(<<EOS)
instance-id: #{yq(@vm_name)}
local-hostname: #{yq(@vm_name)}
EOS

    guest_network = NetAddr.parse_net(vp.read_guest_ephemeral)

    vp.write_dnsmasq_conf(<<DNSMASQ_CONF)
pid-file=
leasefile-ro
enable-ra
dhcp-authoritative
ra-param=tap#{@vm_name}
dhcp-range=#{guest_network.nth(2)},#{guest_network.nth(2)},#{guest_network.netmask.prefix_len}
#{"dhcp-range=tap#{@vm_name},#{vm_sub.nth(1)},#{vm_sub.nth(2**(32 - vm_sub.netmask.prefix_len) - 1)},#{vm_sub.netmask.prefix_len}" if ip4}
dhcp-option=option6:dns-server,2620:fe::fe,2620:fe::9
DNSMASQ_CONF

    vp.write_network_config(<<EOS)
version: 2
ethernets:
  #{yq("enx" + guest_mac.tr(":", "").downcase)}:
    match:
      macaddress: #{yq(guest_mac)}
    dhcp6: true
    #{"dhcp4: true" if ip4}
EOS

    write_user_data(unix_user, public_key)

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
    inactive: False
    shell: /bin/bash
    ssh_authorized_keys:
      - #{yq(public_key)}

ssh_pwauth: False

runcmd:
  - [ systemctl, daemon-reload]
EOS
  end

  def storage(storage_volumes, boot_image)
    FileUtils.mkdir_p vp.storage("")
    storage_volumes.map.with_index { |volume, idx|
      setup_volume(volume, idx, boot_image)
    }
  end

  def setup_volume(storage_volume, index, boot_image)
    disk_file = setup_disk_file(storage_volume, index, boot_image)
    q_disk_file = disk_file.shellescape

    FileUtils.chown @vm_name, @vm_name, disk_file

    # don't allow others to read user's disk
    FileUtils.chmod "u=rw,g=r,o=", disk_file

    # allow spdk to access the image
    r "setfacl -m u:spdk:rw #{q_disk_file}"

    q_bdev = storage_volume["device_id"].shellescape
    vhost = "#{@vm_name}_#{index}".shellescape
    r "#{Spdk.rpc_py} bdev_aio_create #{q_disk_file} #{q_bdev} 512"
    r "#{Spdk.rpc_py} vhost_create_blk_controller #{vhost.shellescape} #{q_bdev}"

    # create a symlink to the socket in the per vm storage dir
    FileUtils.ln_s Spdk.vhost_sock(vhost), vp.vhost_sock(index)

    # allow vm user to access the vhost socket
    r "setfacl -m u:#{@vm_name}:rw #{vp.vhost_sock(index).shellescape}"

    vp.vhost_sock(index)
  end

  def setup_disk_file(storage_volume, index, boot_image)
    disk_file = vp.disk(index)
    q_disk_file = disk_file.shellescape

    if storage_volume["boot"]
      image_path = download_boot_image(boot_image)

      # Images are presumed to be atomically renamed into the path,
      # i.e. no partial images will be passed to qemu-image.
      r "qemu-img convert -p -f qcow2 -O raw #{image_path.shellescape} #{q_disk_file}"

      size = File.size(disk_file)

      fail "Image size greater than requested disk size" unless size <= storage_volume["size_gib"] * 2**30
    else
      FileUtils.touch(disk_file)
    end

    r "truncate -s #{storage_volume["size_gib"]}G #{q_disk_file}"

    disk_file
  end

  def download_boot_image(boot_image)
    urls = {
      "ubuntu-jammy" => "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
      "almalinux-9.1" => "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.1-20221118.x86_64.qcow2",
      "opensuse-leap-15.4" => "https://download.opensuse.org/distribution/leap/15.4/appliances/openSUSE-Leap-15.4-Minimal-VM.x86_64-OpenStack-Cloud.qcow2"
    }

    download = urls.fetch(boot_image)
    image_path = "/opt/" + boot_image + ".qcow2"
    unless File.exist?(image_path)
      # Use of File::EXCL provokes a crash rather than a race
      # condition if two VMs are lazily getting their images at the
      # same time.
      #
      # YYY: Need to replace this with something that can handle
      # customer images.  As-is, it does not have all the
      # synchronization features we might want if we were to keep this
      # code longer term, but, that's not the plan.
      temp_path = image_path + ".tmp"
      File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
        r "curl -L10 -o #{temp_path.shellescape} #{download.shellescape}"
      end
      FileUtils.mv(temp_path, image_path)
    end

    image_path
  end

  # Unnecessary if host has this set before creating the netns, but
  # harmless and fast enough to double up.
  def forwarding
    r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.conf.all.forwarding=1")
    r("ip netns exec #{q_vm} sysctl -w net.ipv4.ip_forward=1")
  end

  def install_systemd_unit(max_vcpus, cpu_topology, mem_gib, vhost_sockets)
    cpu_setting = "boot=#{max_vcpus},topology=#{cpu_topology}"

    vp.write_dnsmasq_service <<DNSMASQ_SERVICE
[Unit]
Description=A lightweight DHCP and caching DNS server
After=network.target

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
Type=simple
ExecStartPre=/usr/local/sbin/dnsmasq --test
ExecStart=/usr/local/sbin/dnsmasq -k -h -C /vm/#{@vm_name}/dnsmasq.conf --log-debug -i tap#{@vm_name} --user=#{@vm_name} --group=#{@vm_name}
ExecReload=/bin/kill -HUP $MAINPID
# YYY: These are not enough capabilties, at least CAP_NET_RAW is
# needed, as well as more for setgid
# CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
# AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
ProtectSystem=strict
PrivateDevices=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectHome=yes
NoNewPrivileges=yes
ReadOnlyPaths=/
DNSMASQ_SERVICE

    disk_params = vhost_sockets.map { |socket|
      "--disk vhost_user=true,socket=#{socket},num_queues=1,queue_size=256 \\"
    }

    # YYY: Do something about systemd escaping, i.e. research the
    # rules and write a routine for it.  Banning suspicious strings
    # from VmPath is also a good idea.
    fail "BUG" if /["'\s]/.match?(cpu_setting)
    vp.write_systemd_service <<SERVICE
[Unit]
Description=#{@vm_name}
After=network.target
After=#{@vm_name}-dnsmasq.service
Requires=#{@vm_name}-dnsmasq.service

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
ExecStartPre=/usr/bin/rm -f #{vp.ch_api_sock}

ExecStart=/opt/cloud-hypervisor/v#{CloudHypervisor::VERSION}/cloud-hypervisor \
--api-socket path=#{vp.ch_api_sock} \
--kernel #{CloudHypervisor.firmware} \
#{disk_params.join("\n")}
--disk path=#{vp.cloudinit_img} \
--console off --serial file=#{vp.serial_log} \
--cpus #{cpu_setting} \
--memory size=#{mem_gib}G,hugepages=on,hugepage_size=1G \
--net "mac=#{guest_mac},tap=tap#{@vm_name},ip=,mask="

ExecStop=/opt/cloud-hypervisor/v#{CloudHypervisor::VERSION}/ch-remote --api-socket #{vp.ch_api_sock} shutdown-vmm
Restart=no
User=#{@vm_name}
Group=#{@vm_name}
SERVICE
    r "systemctl daemon-reload"
  end

  # Does not return, replaces process with cloud-hypervisor running the guest.
  def exec_cloud_hypervisor
    require "etc"
    serial_device = if $stdout.tty?
      "tty"
    else
      "file=#{vp.serial_log}"
    end
    u = Etc.getpwnam(@vm_name)
    Dir.chdir(u.dir)
    exec(
      "/usr/sbin/ip", "netns", "exec", @vm_name,
      "/usr/bin/setpriv", "--reuid=#{u.uid}", "--regid=#{u.gid}", "--init-groups", "--reset-env",
      "--",
      "/opt/cloud-hypervisor/v#{CloudHypervisor::VERSION}/cloud-hypervisor",
      "--api-socket", "path=#{vp.ch_api_sock}",
      "--kernel", CloudHypervisor.firmware,
      "--disk", "path=#{vp.boot_raw}",
      "--disk", "path=#{vp.cloudinit_img}",
      "--console", "off", "--serial", serial_device,
      "--cpus", "boot=4",
      "--memory", "size=1024M",
      "--net", "mac=#{guest_mac},tap=tap#{@vm_name},ip=,mask=",
      close_others: true
    )
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

  def guest_mac
    # YYY: Should make this static and saved by control plane, it's
    # not that hard to do, can spare licensed software users some
    # issues:
    # https://stackoverflow.com/questions/55686021/static-mac-addresses-for-ec2-instance
    # https://techcommunity.microsoft.com/t5/itops-talk-blog/understanding-static-mac-address-licensing-in-azure/ba-p/1386187
    #
    # Also necessary because Cloud Hypervisor, at time of writing,
    # does not offer robust PCIe slot mapping of devices.  The MAC
    # address is the most effective stable identifier for the guest in
    # this case.
    @guest_mac ||= begin
      vp.read_guest_mac
    rescue Errno::ENOENT
      gen_mac.tap { vp.write_guest_mac(_1) }
    end
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
