#!/bin/env ruby
# frozen_string_literal: true

require_relative "common"

require "fileutils"
require "netaddr"
require "json"
require "openssl"
require "base64"
require_relative "vm_path"
require_relative "cloud_hypervisor"
require_relative "spdk"
require_relative "storage_key_encryption"

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

  def prep(unix_user, public_key, nics, gua, ip4, local_ip4, boot_image, max_vcpus, cpu_topology, mem_gib, ndp_needed, storage_volumes, storage_secrets)
    setup_networking(false, gua, ip4, local_ip4, nics, ndp_needed)
    cloudinit(unix_user, public_key, nics)
    vhost_sockets = storage(storage_volumes, storage_secrets, boot_image)
    hugepages(mem_gib)
    install_systemd_unit(max_vcpus, cpu_topology, mem_gib, vhost_sockets, nics)
  end

  def recreate_unpersisted(gua, ip4, local_ip4, nics, mem_gib, ndp_needed, storage_volumes, storage_secrets)
    setup_networking(true, gua, ip4, local_ip4, nics, ndp_needed)
    hugepages(mem_gib)

    storage_volumes.each { |volume|
      disk_index = volume["disk_index"]
      device_id = volume["device_id"]
      disk_file = vp.disk(disk_index)
      key_wrapping_secrets = storage_secrets[device_id]
      encryption_key = read_data_encryption_key(disk_index, key_wrapping_secrets) if key_wrapping_secrets
      setup_spdk_bdev(device_id, disk_file, encryption_key)
      setup_spdk_vhost(disk_index, device_id)
    }
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
        write_nat4_config(ip4, nics)
      end
    end

    interfaces(nics)
    setup_veths_6(guest_ephemeral, clover_ephemeral, gua, ndp_needed)
    setup_taps_6(gua, nics)
    routes4(ip4, local_ip4, nics)
    apply_nat4_rules if ip4
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
    r "umount #{vp.q_hugepages}"

    begin
      r "deluser --remove-home #{q_vm}"
    rescue CommandFail => ex
      raise unless /The user `.*' does not exist./.match?(ex.stderr)
    end
  end

  def purge_storage
    params = JSON.parse(File.read(vp.prep_json))
    params["storage_volumes"].each { |disk|
      device_id = disk["device_id"]
      disk_index = disk["disk_index"]

      vhost_controller = Spdk.vhost_controller(@vm_name, disk_index)

      r "#{Spdk.rpc_py} vhost_delete_controller #{vhost_controller.shellescape}"

      if disk["encrypted"]
        q_keyname = "#{device_id}_key".shellescape
        q_aio_bdev = "#{device_id}_aio".shellescape
        r "#{Spdk.rpc_py} bdev_crypto_delete #{device_id.shellescape}"
        r "#{Spdk.rpc_py} bdev_aio_delete #{q_aio_bdev}"
        r "#{Spdk.rpc_py} accel_crypto_key_destroy -n #{q_keyname}"
      else
        r "#{Spdk.rpc_py} bdev_aio_delete #{device_id.shellescape}"
      end

      rm_if_exists(Spdk.vhost_sock(vhost_controller))
    }

    rm_if_exists(vp.storage_root)
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
    nics.each do |ip6, ip4, tap, mac|
      r "ip -n #{q_vm} tuntap add dev #{tap} mode tap user #{q_vm}"
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
    nics.each do |net6, net4, tapname, mac|
      r "ip -n #{q_vm} addr replace #{guest_intrusion.shellescape} dev #{tapname}"

      # Route ephemeral address to tap.
      r "ip -n #{q_vm} link set dev #{tapname} up"
      r "ip -n #{q_vm} route replace #{guest_ephemeral.to_s.shellescape} via #{mac_to_ipv6_link_local(mac)} dev #{tapname}"

      # Route private subnet addresses to tap.
      ip6 = NetAddr::IPv6Net.parse(net6)

      # Allocate ::1 in the guest network for DHCPv6.
      r "ip -n #{q_vm} addr replace #{ip6.nth(1)}/#{ip6.netmask.prefix_len} dev #{tapname}"
      r "ip -n #{q_vm} route replace #{ip6.to_s.shellescape} via #{mac_to_ipv6_link_local(mac)} dev #{tapname}"
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

    nics.each do |net6, net4, tapname, mac|
      r "ip -n #{q_vm} route replace #{vm} dev #{tapname}" if ip4
      r "ip -n #{q_vm} route replace default via #{vetho} dev vethi#{q_vm}"

      r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/vethi#{q_vm}/proxy_arp'"
      r "ip netns exec #{q_vm} bash -c 'echo 1 > /proc/sys/net/ipv4/conf/#{tapname}/proxy_arp'"

      r "ip -n #{q_vm} addr replace 192.168.0.1/16 dev #{tapname}"
      r "ip -n #{q_vm} addr replace 10.0.0.1/8 dev #{tapname}"
      r "ip -n #{q_vm} addr replace 172.16.0.1/12 dev #{tapname}"
    end
  end

  def write_nat4_config(ip4, nics)
    return unless ip4
    public_sub = NetAddr::IPv4Net.parse(ip4)
    public_ipv4 = public_sub.network.to_s

    private_ipv4 = nics.first[1]
    private_sub = NetAddr::IPv4Net.parse(private_ipv4)
    private_ipv4 = private_sub.network.to_s

    vp.write_nftables_conf(<<NFTABLES_CONF)
table ip raw {
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    ip daddr #{public_ipv4} ip daddr set #{private_ipv4} notrack
    ip saddr #{private_ipv4} ip daddr != { 192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8 } ip saddr set #{public_ipv4} notrack
  }
}
NFTABLES_CONF
  end

  def apply_nat4_rules
    # We first flush the ruleset to make this function idempotent
    r "ip netns exec #{q_vm} bash -c 'nft flush ruleset'"
    r "ip netns exec #{q_vm} bash -c 'nft -f #{vp.q_nftables_conf}'"
  end

  def cloudinit(unix_user, public_key, nics)
    vp.write_meta_data(<<EOS)
instance-id: #{yq(@vm_name)}
local-hostname: #{yq(@vm_name)}
EOS

    guest_network = NetAddr.parse_net(vp.read_guest_ephemeral)
    private_ip_dhcp = nics.map do |net6, net4, tapname, mac|
      vm_sub_6 = NetAddr::IPv6Net.parse(net6)
      vm_sub_4 = NetAddr::IPv4Net.parse(net4)
      <<DHCP
dhcp-range=#{tapname},#{vm_sub_4.nth(0)},#{vm_sub_4.nth(0)},#{vm_sub_4.netmask.prefix_len}
dhcp-range=#{tapname},#{vm_sub_6.nth(2)},#{vm_sub_6.nth(2)},#{vm_sub_6.netmask.prefix_len}
DHCP
    end.join("\n")

    raparams = nics.map { |net6, net4, tapname, mac| "ra-param=#{tapname}" }.join("\n")

    vp.write_dnsmasq_conf(<<DNSMASQ_CONF)
pid-file=
leasefile-ro
enable-ra
dhcp-authoritative
#{raparams}
dhcp-range=#{guest_network.nth(2)},#{guest_network.nth(2)},#{guest_network.netmask.prefix_len}
#{private_ip_dhcp}
dhcp-option=option6:dns-server,2620:fe::fe,2620:fe::9
DNSMASQ_CONF

    ethernets = nics.map do |net6, net4, tapname, mac|
      <<ETHERNETS
  #{yq("enx" + mac.tr(":", "").downcase)}:
    match:
      macaddress: #{mac}
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

  def storage(storage_volumes, storage_secrets, boot_image)
    storage_volumes.map { |volume|
      disk_index = volume["disk_index"]
      FileUtils.mkdir_p vp.storage(disk_index, "")
      device_id = volume["device_id"]
      key_wrapping_secrets = storage_secrets[device_id]
      setup_volume(volume, disk_index, boot_image, key_wrapping_secrets)
      setup_spdk_vhost(disk_index, device_id)
    }
  end

  def setup_volume(storage_volume, disk_index, boot_image, key_wrapping_secrets)
    encrypted = !key_wrapping_secrets.nil?
    encryption_key = setup_data_encryption_key(disk_index, key_wrapping_secrets) if encrypted

    disk_file = setup_disk_file(storage_volume, disk_index)

    if storage_volume["boot"]
      copy_image(disk_file, boot_image,
        storage_volume["size_gib"],
        encryption_key)
    end

    bdev = storage_volume["device_id"]
    setup_spdk_bdev(bdev, disk_file, encryption_key)
  end

  def setup_spdk_bdev(bdev, disk_file, encryption_key)
    q_bdev = bdev.shellescape
    q_disk_file = disk_file.shellescape

    if encryption_key
      q_keyname = "#{bdev}_key".shellescape
      q_aio_bdev = "#{bdev}_aio".shellescape
      r "#{Spdk.rpc_py} accel_crypto_key_create " \
        "-c #{encryption_key[:cipher].shellescape} " \
        "-k #{encryption_key[:key].shellescape} " \
        "-e #{encryption_key[:key2].shellescape} " \
        "-n #{q_keyname}"
      r "#{Spdk.rpc_py} bdev_aio_create #{q_disk_file} #{q_aio_bdev} 512"
      r "#{Spdk.rpc_py} bdev_crypto_create -n #{q_keyname} #{q_aio_bdev} #{q_bdev}"
    else
      r "#{Spdk.rpc_py} bdev_aio_create #{q_disk_file} #{q_bdev} 512"
    end
  end

  def setup_spdk_vhost(disk_index, device_id)
    q_bdev = device_id.shellescape
    vhost_controller = Spdk.vhost_controller(@vm_name, disk_index)
    spdk_vhost_sock = Spdk.vhost_sock(vhost_controller)

    r "#{Spdk.rpc_py} vhost_create_blk_controller #{vhost_controller.shellescape} #{q_bdev}"

    # don't allow others to access the vhost socket
    FileUtils.chmod "u=rw,g=r,o=", spdk_vhost_sock

    # allow vm user to access the vhost socket
    r "setfacl -m u:#{@vm_name}:rw #{spdk_vhost_sock.shellescape}"

    # create a symlink to the socket in the per vm storage dir
    rm_if_exists(vp.vhost_sock(disk_index))
    FileUtils.ln_s spdk_vhost_sock, vp.vhost_sock(disk_index)

    # Change ownership of the symlink. FileUtils.chown uses File.lchown for
    # symlinks and doesn't follow links. We don't use File.lchown directly
    # because it expects numeric uid & gid, which is less convenient.
    FileUtils.chown @vm_name, @vm_name, vp.vhost_sock(disk_index)

    vp.vhost_sock(disk_index)
  end

  def setup_data_encryption_key(disk_index, key_wrapping_secrets)
    data_encryption_key = OpenSSL::Cipher.new("aes-256-xts").random_key.unpack1("H*")

    result = {
      cipher: "AES_XTS",
      key: data_encryption_key[..63],
      key2: data_encryption_key[64..]
    }

    key_file = vp.data_encryption_key(disk_index)

    # save encrypted key
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.write_encrypted_dek(key_file, result)

    FileUtils.chown @vm_name, @vm_name, key_file
    FileUtils.chmod "u=rw,g=,o=", key_file

    sync_parent_dir(key_file)

    result
  end

  def read_data_encryption_key(disk_index, key_wrapping_secrets)
    key_file = vp.data_encryption_key(disk_index)
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.read_encrypted_dek(key_file)
  end

  def copy_image(disk_file, boot_image, disk_size_gib, encryption_key)
    image_path = download_boot_image(boot_image)
    encrypted = !encryption_key.nil?

    size = File.size(image_path)

    fail "Image size greater than requested disk size" unless size <= disk_size_gib * 2**30

    # Note that spdk_dd doesn't interact with the main spdk process. It is a
    # tool which starts the spdk infra as a separate process, creates bdevs
    # from config, does the copy, and exits. Since it is a separate process
    # for each image, although bdev names are same, they don't conflict.
    # Goal is to copy the image into disk_file, which will be registered
    # in the main spdk daemon after this function returns.

    bdev_conf = [{
      method: "bdev_aio_create",
      params: {
        name: "aio0",
        block_size: 512,
        filename: disk_file,
        readonly: false
      }
    }]

    if encrypted
      bdev_conf.append({
        method: "bdev_crypto_create",
        params: {
          base_bdev_name: "aio0",
          name: "crypt0",
          key_name: "super_key"
        }
      })
    end

    accel_conf = []
    if encrypted
      accel_conf.append(
        {
          method: "accel_crypto_key_create",
          params: {
            name: "super_key",
            cipher: encryption_key[:cipher],
            key: encryption_key[:key],
            key2: encryption_key[:key2]
          }
        }
      )
    end

    spdk_config_json = {
      subsystems: [
        {
          subsystem: "accel",
          config: accel_conf
        },
        {
          subsystem: "bdev",
          config: bdev_conf
        }
      ]
    }.to_json

    target_bdev = if encrypted
      "crypt0"
    else
      "aio0"
    end

    # spdk_dd uses the same spdk app infra, so it will bind to an rpc socket,
    # which we won't use. But its path shouldn't conflict with other VM setups,
    # so it doesn't error out in concurrent VM creations.
    rpc_socket = "/var/tmp/spdk_dd.sock.#{@vm_name}"

    r("#{Spdk.bin("spdk_dd")} --config /dev/stdin " \
    "--disable-cpumask-locks " \
    "--rpc-socket #{rpc_socket.shellescape} " \
    "--if #{image_path.shellescape} " \
    "--ob #{target_bdev.shellescape} " \
    "--bs=2097152", stdin: spdk_config_json)
  end

  def setup_disk_file(storage_volume, disk_index)
    disk_file = vp.disk(disk_index)
    q_disk_file = disk_file.shellescape

    FileUtils.touch(disk_file)
    r "truncate -s #{storage_volume["size_gib"]}G #{q_disk_file}"

    FileUtils.chown @vm_name, @vm_name, disk_file

    # don't allow others to read user's disk
    FileUtils.chmod "u=rw,g=r,o=", disk_file

    # allow spdk to access the image
    r "setfacl -m u:spdk:rw #{disk_file.shellescape}"
    disk_file
  end

  def download_boot_image(boot_image)
    urls = {
      "ubuntu-jammy" => "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
      "almalinux-9.1" => "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-9.1-20221118.x86_64.qcow2",
      "opensuse-leap-15.4" => "https://download.opensuse.org/distribution/leap/15.4/appliances/openSUSE-Leap-15.4-Minimal-VM.x86_64-OpenStack-Cloud.qcow2"
    }

    download = urls.fetch(boot_image)
    image_path = "/opt/" + boot_image + ".raw"
    unless File.exist?(image_path)
      # Use of File::EXCL provokes a crash rather than a race
      # condition if two VMs are lazily getting their images at the
      # same time.
      #
      # YYY: Need to replace this with something that can handle
      # customer images.  As-is, it does not have all the
      # synchronization features we might want if we were to keep this
      # code longer term, but, that's not the plan.
      temp_path = "/opt/" + boot_image + ".qcow2.tmp"
      File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
        r "curl -L10 -o #{temp_path.shellescape} #{download.shellescape}"
      end

      # Images are presumed to be atomically renamed into the path,
      # i.e. no partial images will be passed to qemu-image.
      r "qemu-img convert -p -f qcow2 -O raw #{temp_path.shellescape} #{image_path.shellescape}"
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

  def install_systemd_unit(max_vcpus, cpu_topology, mem_gib, vhost_sockets, nics)
    cpu_setting = "boot=#{max_vcpus},topology=#{cpu_topology}"

    tapnames = nics.map { |net6, net4, tap, mac|
      "-i #{tap}"
    }.join(" ")

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

    net_params = nics.map { |net6, net4, tap, mac|
      "--net mac=#{mac},tap=#{tap},ip=,mask="
    }

    # YYY: Do something about systemd escaping, i.e. research the
    # rules and write a routine for it.  Banning suspicious strings
    # from VmPath is also a good idea.
    fail "BUG" if /["'\s]/.match?(cpu_setting)
    vp.write_systemd_service <<SERVICE
[Unit]
Description=#{@vm_name}
After=network.target
After=spdk.service
After=#{@vm_name}-dnsmasq.service
Requires=#{@vm_name}-dnsmasq.service
Requires=spdk.service

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
#{net_params.join(" \\\n")}

ExecStop=/opt/cloud-hypervisor/v#{CloudHypervisor::VERSION}/ch-remote --api-socket #{vp.ch_api_sock} shutdown-vmm
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
