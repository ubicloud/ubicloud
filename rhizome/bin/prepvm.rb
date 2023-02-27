#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

# "Global Unicast" subnet, i.e. a subnet for exchanging packets with
# the internet.
unless (gua = ARGV.shift)
  puts "need global unicast subnet as argument"
  exit 1
end

q_vm = vm_name.shellescape
r "adduser --disabled-password --gecos '' #{q_vm}"
r "usermod -a -G kvm #{q_vm}"
r "ip netns add #{q_vm}"
r "ip link add vetho#{q_vm} type veth peer name vethi#{q_vm} netns #{q_vm}"
r "ip -n #{q_vm} tuntap add dev tap#{q_vm} mode tap user #{q_vm}"

def mac_to_ipv6_link_local(mac)
  eui = mac.split(":").map(&:hex)
  eui.insert(3, 0xff, 0xfe)
  eui[0] ^= 0x02

  "fe80::" + eui.each_slice(2).map { |pair|
    pair.map { format("%02x", _1) }.join
  }.join(":")
end

# Routing: from host to subordinate.
vethi_ll = mac_to_ipv6_link_local(r("ip netns exec #{q_vm} cat /sys/class/net/vethi#{q_vm}/address"))
r "ip link set dev vetho#{q_vm} up"
r "ip route add #{gua.shellescape} via #{vethi_ll.shellescape} dev vetho#{q_vm}"

# From subordinate to host.
vetho_ll = mac_to_ipv6_link_local(File.read("/sys/class/net/vetho#{q_vm}/address"))
r "ip -n #{q_vm} link set dev vethi#{q_vm} up"
r "ip -n #{q_vm} route add default via #{vetho_ll.shellescape} dev vethi#{q_vm}"

def gen_mac
  ([rand(256) & 0xFE | 0x02] + 5.times.map { rand(256) }).map { "%0.2X" % _1 }.join(":").downcase
end

guest_mac = gen_mac
File.write("/home/#{q_vm}/guest_mac", guest_mac + "\n")

# Write out ephemeral public IP and IPsec addresses.
require "ipaddr"
ephemeral = IPAddr.new(gua).succ
ipsec = ephemeral.succ.to_s
ephemeral = ephemeral.to_s
File.write("/home/#{q_vm}/ephemeral", ephemeral + "\n")
File.write("/home/#{q_vm}/ipsec", ipsec + "\n")

# Route ephemeral address to tap.
r "ip -n #{q_vm} link set dev tap#{q_vm} up"
r "ip -n #{q_vm} route add #{ephemeral} via #{mac_to_ipv6_link_local(guest_mac)} dev tap#{q_vm}"

# Prepare cloudinit data.
File.write("/home/#{q_vm}/meta-data", <<EOS)
instance-id: #{q_vm}
local-hostname: #{q_vm}
EOS

tap_mac = r("ip netns exec #{q_vm} cat /sys/class/net/tap#{q_vm}/address")
File.write("/home/#{q_vm}/network-config", <<EOS)
version: 2
ethernets:
  id0:
    match:
      macaddress: "#{guest_mac}"
    addresses: [#{ephemeral}/128]
    gateway6: #{mac_to_ipv6_link_local(tap_mac)}
    nameservers:
      addresses: [2a01:4ff:ff00::add:1, 2a01:4ff:ff00::add:2]
EOS

File.write("/home/#{q_vm}/user-data", <<EOS)
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

r "mkdosfs -n CIDATA -C /home/#{q_vm}/ubuntu-cloudinit.img 8192"
r "mcopy -oi /home/#{q_vm}/ubuntu-cloudinit.img -s /home/#{q_vm}/user-data ::"
r "mcopy -oi /home/#{q_vm}/ubuntu-cloudinit.img -s /home/#{q_vm}/meta-data ::"
r "mcopy -oi /home/#{q_vm}/ubuntu-cloudinit.img -s /home/#{q_vm}/network-config ::"
r "chown #{q_vm}:#{q_vm} /home/#{q_vm}/ubuntu-cloudinit.img"

r "qemu-img convert -p -f qcow2 -O raw /opt/cloud-hypervisor/focal-server-cloudimg-amd64.img /home/#{q_vm}/focal-server-cloudimg-amd64.raw"
r "chown #{q_vm}:#{q_vm} /home/#{q_vm}/focal-server-cloudimg-amd64.raw"

# All systems go.
r("ip netns exec #{q_vm} sysctl -w net.ipv6.conf.all.forwarding=1")
