# frozen_string_literal: true

class Prog::Vnet::RekeyTunnel < Prog::Base
  subject_is :nic

  def start
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    outs = ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm policy").split("\n")
    old_spi = outs[outs.find_index("src #{ipsec_tunnel.src_nic.private_ipv4} dst #{ipsec_tunnel.dst_nic.private_ipv4} ")+3].split(" ")[3]

    new_spi = "0x" + SecureRandom.bytes(4).unpack1("H*")
    new_key = "0x" + SecureRandom.bytes(36).unpack1("H*")
    new_reqid = SecureRandom.random_number(100000) + 1

    strand.stack.last["old_spi"] = old_spi
    strand.stack.last["new_spi"] = new_spi
    strand.stack.last["new_key"] = new_key
    strand.stack.last["new_reqid"] = new_reqid

    bud self.class, strand.stack.last, :setup_src_state
    bud self.class, strand.stack.last, :setup_dst_state
    
    puts "STACK IN START: #{strand.stack}"

    hop :wait_setups
  end

  def wait_setups
    reap
    hop :drop_old_states if leaf?
    donate
  end

  def drop_old_states
    puts "STACK : #{strand.stack}"
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi"]}")

    ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi"]}")

    pop "rekeying is complete"
  end

  def setup_src_state
    new_spi = strand.stack.last["new_spi"]
    new_key = strand.stack.last["new_key"]
    new_reqid = strand.stack.last["new_reqid"]

    ipsec_tunnel = nic.src_ipsec_tunnels.first
    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(nic)} xfrm state add " \
      "src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{new_spi} reqid #{new_reqid} mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{new_key} 128 " \
      "sel src 0.0.0.0/0 dst 0.0.0.0/0")

    hop :setup_src_policy
  end

  def setup_src_policy
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    new_spi = strand.stack.last["new_spi"]
    new_reqid = strand.stack.last["new_reqid"]

    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(nic)} xfrm policy update " \
      "src #{nic.private_ipv4} " \
      "dst #{ipsec_tunnel.dst_nic.private_ipv4} dir out " \
      "tmpl src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "spi #{new_spi} proto esp reqid #{new_reqid} mode tunnel")

    pop "setup tunnel src end"
  end

  def setup_dst_state
    new_spi = strand.stack.last["new_spi"]
    new_key = strand.stack.last["new_key"]
    new_reqid = strand.stack.last["new_reqid"]

    ipsec_tunnel = nic.src_ipsec_tunnels.first
    ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state add " \
      "src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{new_spi} reqid #{new_reqid} mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{new_key} 128 " \
      "sel src 0.0.0.0/0 dst 0.0.0.0/0")

    hop :setup_dst_policy
  end

  def setup_dst_policy
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    new_spi = strand.stack.last["new_spi"]
    new_reqid = strand.stack.last["new_reqid"]

    ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm policy update " \
      "src #{nic.private_ipv4} " \
      "dst #{ipsec_tunnel.dst_nic.private_ipv4} dir fwd " \
      "tmpl src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "spi #{new_spi} proto esp reqid #{new_reqid} mode tunnel")

    pop "setup tunnel dst end"
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    halved.next_sib
  end
end
