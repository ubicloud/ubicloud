#!/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require_relative "common"
require_relative "vm_path"

class VmSetup
  def initialize(vm_name)
    @vm_name = vm_name
  end

  def q_vm
    @q_vm ||= @vm_name.shellescape
  end

  # YAML quoting
  def yq(s)
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
    YAML.dump(s)[4..-2]
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def prep(gua)
    unix_user
    interfaces
    routes(gua)
    cloudinit
    boot_disk
    forwarding
  end

  def network(gua)
    interfaces
    routes(gua)
    cloudinit
    forwarding
  end

  # Delete all traces of the VM.
  def purge
    r "deluser --remove-home #{q_vm}"
    r "ip netns del #{q_vm}"
  end

  def unix_user
    r "adduser --disabled-password --gecos '' #{q_vm}"
    r "usermod -a -G kvm #{q_vm}"
  end

  def interfaces
    r "ip netns add #{q_vm}"
    r "ip link add vetho#{q_vm} type veth peer name vethi#{q_vm} netns #{q_vm}"
    r "ip -n #{q_vm} tuntap add dev tap#{q_vm} mode tap user #{q_vm}"
  end

  def routes(gua)
    # Routing: from host to subordinate.
    vethi_ll = mac_to_ipv6_link_local(r("ip netns exec #{q_vm} cat /sys/class/net/vethi#{q_vm}/address").chomp)
    r "ip link set dev vetho#{q_vm} up"
    r "ip route add #{gua.shellescape} via #{vethi_ll.shellescape} dev vetho#{q_vm}"

    # From subordinate to host.
    vetho_ll = mac_to_ipv6_link_local(File.read("/sys/class/net/vetho#{q_vm}/address").chomp)
    r "ip -n #{q_vm} link set dev vethi#{q_vm} up"
    r "ip -n #{q_vm} route add default via #{vetho_ll.shellescape} dev vethi#{q_vm}"

    # Write out ephemeral public IP and IPsec addresses.
    require "ipaddr"
    ephemeral = IPAddr.new(gua).succ

    # YYY: Would be better to figure out what subnet size we wish to
    # delegate to the namespace, and then slice off half of it for our
    # own use, and the other half for the customer.  Effectively,
    # there'd be a bit that would separate our internal use from the
    # customer.
    #
    # As-is, the gua subnet just needs two addresses, and this code
    # allocates two consecutive addresses: one for ipsec, one for
    # ephemeral internet access.
    ipsec = ephemeral.succ.to_s
    ephemeral = ephemeral.to_s
    vp.write_ephemeral(ephemeral)
    vp.write_ipsec(ipsec)

    # Route ephemeral address to tap.
    r "ip -n #{q_vm} link set dev tap#{q_vm} up"
    r "ip -n #{q_vm} route add #{ephemeral} via #{mac_to_ipv6_link_local(guest_mac)} dev tap#{q_vm}"
  end

  def cloudinit
    require "yaml"

    vp.write_meta_data(<<EOS)
instance-id: #{yq(@vm_name)}
local-hostname: #{yq(@vm_name)}
EOS

    tap_mac = r("ip netns exec #{q_vm} cat /sys/class/net/tap#{q_vm}/address")

    vp.write_network_config(<<EOS)
version: 2
ethernets:
  id0:
    match:
      macaddress: #{yq(guest_mac)}
    addresses: [#{yq(vp.read_ephemeral + "/128")}]
    gateway6: #{yq(mac_to_ipv6_link_local(tap_mac))}
    nameservers:
      addresses: [2a01:4ff:ff00::add:1, 2a01:4ff:ff00::add:2]
EOS

    vp.write_user_data(<<EOS)
#cloud-config
users:
  - name: cloud
    passwd: $6$7125787751a8d18a$sHwGySomUA1PawiNFWVCKYQN.Ec.Wzz0JtPPL1MvzFrkwmop2dq7.4CYf03A5oemPQ4pOFCCrtCelvFBEle/K.
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: False
    inactive: False
    shell: /bin/bash

ssh_pwauth: False

runcmd:
  - [ systemctl, daemon-reload]
  - [ systemctl, enable, notify-booted.service]
  - [ systemctl, start, --no-block, notify-booted.service ]
EOS

    r "mkdosfs -n CIDATA -C #{vp.q_cloudinit_img} 8192"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_user_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_meta_data} ::"
    r "mcopy -oi #{vp.q_cloudinit_img} -s #{vp.q_network_config} ::"
    FileUtils.chown @vm_name, @vm_name, vp.cloudinit_img
  end

  def boot_disk
    r "qemu-img convert -p -f qcow2 -O raw /opt/jammy-server-cloudimg-amd64.img #{vp.q_boot_raw}"
    r "chown #{q_vm}:#{q_vm} #{vp.q_boot_raw}"
  end

  # Unnecessary if host has this set before creating the netns, but
  # harmless and fast enough to double up.
  def forwarding
    r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
  end

  # Does not return, replaces process with cloud-hypervisor running the guest.
  def exec_cloud_hypervisor
    require "etc"
    serial_device = if $stdout.tty?
      "tty"
    else
      "file=serial.log"
    end
    u = Etc.getpwnam(@vm_name)
    Dir.chdir(u.dir)
    exec(
      "/usr/sbin/ip", "netns", "exec", @vm_name,
      "/usr/bin/setpriv", "--reuid=#{u.uid}", "--regid=#{u.gid}", "--init-groups", "--reset-env",
      "--",
      "/opt/cloud-hypervisor/v30.0/cloud-hypervisor",
      "--kernel", "/opt/fw/v0.4.2/hypervisor-fw",
      "--disk", "path=#{vp.boot_raw}",
      "--disk", "path=#{vp.cloudinit_img}",
      "--console", "off", "--serial", serial_device,
      "--cpus", "boot=4",
      "--memory", "size=1024M",
      "--net", "mac=#{guest_mac},tap=tap#{@vm_name},ip=,mask=",
      close_others: true
    )
  end

  def guest_mac
    @guest_mac ||= begin
      vp.read_guest_mac
    rescue Errno::ENOENT
      # Generate a MAC with the "local" (generated, non-manufacturer)
      # bit set and the multicast bit cleared in the first octet.
      #
      # Accuracy here are is not a formality: otherwise assigning a
      # ipv6 link local address errors out.
      #
      # YYY: Should make this static and saved by control plane, it's
      # not that hard to do, can spare licensed software users some
      # issues:
      # https://stackoverflow.com/questions/55686021/static-mac-addresses-for-ec2-instance
      # https://techcommunity.microsoft.com/t5/itops-talk-blog/understanding-static-mac-address-licensing-in-azure/ba-p/1386187
      ([rand(256) & 0xFE | 0x02] + 5.times.map { rand(256) }).map {
        "%0.2X" % _1
      }.join(":").downcase.tap {
        vp.write_guest_mac(_1)
      }
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
