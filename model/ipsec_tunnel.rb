# frozen_string_literal: true

require_relative "../model"

class IpsecTunnel < Sequel::Model
  many_to_one :src_nic, key: :src_nic_id, class: Nic
  many_to_one :dst_nic, key: :dst_nic_id, class: Nic

  include ResourceMethods

  def cmd_src_nic(cmd)
    src_nic.vm.vm_host.sshable.cmd(cmd)
  end

  def cmd_dst_nic(cmd)
    dst_nic.vm.vm_host.sshable.cmd(cmd)
  end

  def refresh
    create_ipsec_tunnel
    create_private_routes
  end

  def add_new_state
    spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    spi4 = "0x" + SecureRandom.bytes(4).unpack1("H*")

    src_nic.vm.vm_host.sshable.cmd("")
  end

  def create_ipsec_tunnel
    src_namespace = vm_name(src_nic)
    dst_namespace = vm_name(dst_nic)
    src_clover_ephemeral = subdivide_network(src_nic.vm.ephemeral_net6)
    dst_clover_ephemeral = subdivide_network(dst_nic.vm.ephemeral_net6)
    src_private_addr_6 = src_nic.private_ipv6.to_s.shellescape
    dst_private_addr_6 = dst_nic.private_ipv6.to_s.shellescape
    src_private_addr_4 = src_nic.private_ipv4.to_s.shellescape
    dst_private_addr_4 = dst_nic.private_ipv4.to_s.shellescape
    src_direction = "out"
    dst_direction = "fwd"

    spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    spi4 = "0x" + SecureRandom.bytes(4).unpack1("H*")
    key = src_nic.encryption_key

    # setup source ipsec tunnels
    cmd_src_nic("sudo bin/setup-ipsec " \
      "#{src_namespace} #{src_clover_ephemeral} " \
      "#{dst_clover_ephemeral} #{src_private_addr_6} " \
      "#{dst_private_addr_6} #{src_private_addr_4} " \
      "#{dst_private_addr_4} #{src_direction} " \
      "#{spi} #{spi4} #{key}")

    # setup destination ipsec tunnels
    cmd_dst_nic("sudo bin/setup-ipsec " \
      "#{dst_namespace} #{src_clover_ephemeral} " \
      "#{dst_clover_ephemeral} #{src_private_addr_6} " \
      "#{dst_private_addr_6} #{src_private_addr_4} " \
      "#{dst_private_addr_4} #{dst_direction} " \
      "#{spi} #{spi4} #{key}")
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    halved.next_sib
  end

  def vm_name(nic)
    nic.vm.inhost_name.shellescape
  end

  def create_private_routes
    [dst_nic.private_ipv6, dst_nic.private_ipv4].each do |dst_ip|
      cmd_src_nic("sudo ip -n #{vm_name(src_nic)} route replace #{dst_ip.to_s.shellescape} dev vethi#{vm_name(src_nic)}")
    end
  end
end
