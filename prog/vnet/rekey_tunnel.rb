# frozen_string_literal: true

class Prog::Vnet::RekeyTunnel < Prog::Base
  subject_is :nic

  def start
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    outs = ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm policy").split("\n")
    old_spi = outs[outs.find_index("src 172.26.207.141/32 dst 172.26.207.155/32 ")+3].split(" ")[3]
    puts "SPI: #{old_spi}"

    new_spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    new_key = "0x" + SecureRandom.bytes(36).unpack1("H*")

    frame["old_spi"] = old_spi
    frame["new_spi"] = new_spi
    frame["new_key"] = new_key

    bud self.class, frame, :setup_src_end
    bud self.class, frame, :setup_dst_end
    
    hop :wait_setups
  end

  def wait_setups
    # reap
    # hop :delete_policies if leaf?
    donate
  end

  def setup_src_end
    puts "srcOLD SPI: #{frame["old_spi"]}"
    puts "srcNEW SPI: #{frame["new_spi"]}"
    puts "srcNEW KEY: #{frame["new_key"]}"
    pop "setup src end"
  end

  def setup_dst_end
    puts "OLD SPI: #{frame["old_spi"]}"
    puts "NEW SPI: #{frame["new_spi"]}"
    puts "NEW KEY: #{frame["new_key"]}"
    pop "setup dst end"
  end

  def delete_policies
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    halved.next_sib
  end

  def old_spi
    @old_spi
  end

  def create_new_state
    puts "OLD SPI: #{old_spi}"
    donate

    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm state add " \
    "src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6)} " \
    "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6)} " \
    "proto esp spi #{new_spi} reqid #{SecureRandom.random_number(10)} mode tunnel " \
    "aead 'rfc4106(gcm(aes))' #{new_key} 128")

  ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state add " \
    "src #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6)} " \
    "dst #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6)} " \
    "proto esp spi #{new_spi} reqid #{SecureRandom.random_number(10)} mode tunnel " \
    "aead 'rfc4106(gcm(aes))' #{new_key} 128")

    puts "HELLLOOOO"
  ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm policy add " \
    "src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "tmpl src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "proto esp spi #{new_spi} mode tunnel reqid #{SecureRandom.random_number(10)} dir out")
puts "HEETETET"
  ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm policy add " \
    "src #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "tmpl src #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "proto esp spi #{new_spi} mode tunnel reqid #{SecureRandom.random_number(10)} dir fwd")

  ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm state delete" \
    " src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "proto esp spi #{old_spi} reqid 1 mode tunnel ")

  ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state delete" \
    " src #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
    "dst #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
    "proto esp spi #{old_spi} reqid 1 mode tunnel ")


    hop :create_new_policy
  end

  def create_new_policy
    ipsec_tunnel.create_new_policy
    hop :delete_old_state
  end

  def delete_old_state
    ipsec_tunnel.delete_old_state
    hop :delete_old_policy
  end

  def delete_old_policy
    ipsec_tunnel.delete_old_policy
    pop "rekeyed tunnel"
  end
end
