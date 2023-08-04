# frozen_string_literal: true

class Prog::Vnet::RekeyTunnel < Prog::Base
  subject_is :nic

  def start
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    outs = ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm policy").split("\n")
    old_spi4 = outs[outs.find_index("src #{ipsec_tunnel.src_nic.private_ipv4} dst #{ipsec_tunnel.dst_nic.private_ipv4} ")+3].split(" ")[3]
    old_spi6 = outs[outs.find_index("src #{ipsec_tunnel.src_nic.private_ipv6} dst #{ipsec_tunnel.dst_nic.private_ipv6} ")+3].split(" ")[3]

    strand.stack.last["old_spi4"] = old_spi4
    strand.stack.last["old_spi6"] = old_spi6
    strand.stack.last["new_spi4"] = "0x" + SecureRandom.bytes(4).unpack1("H*")
    strand.stack.last["new_spi6"] = "0x" + SecureRandom.bytes(4).unpack1("H*")

    strand.stack.last["new_key"] = "0x" + SecureRandom.bytes(36).unpack1("H*")
    strand.stack.last["new_reqid"] = SecureRandom.random_number(100000) + 1

    strand.stack.last["dir"] = "out"
    bud self.class, strand.stack.last, :setup_state
    strand.stack.last["dir"] = "fwd"
    bud self.class, strand.stack.last, :setup_state

    strand.stack.last["ipv6"] = true
    strand.stack.last["dir"] = "out"
    bud self.class, strand.stack.last, :setup_state
    strand.stack.last["dir"] = "fwd"
    bud self.class, strand.stack.last, :setup_state
    
    hop :wait_setups
  end

  def wait_setups
    reap
    hop :drop_old_states if leaf?
    donate
  end

  def setup_state
    is_ipv6 = strand.stack.last["ipv6"]
    new_spi = is_ipv6 ? strand.stack.last["new_spi6"] : strand.stack.last["new_spi4"]
    new_key = strand.stack.last["new_key"]
    new_reqid = strand.stack.last["new_reqid"]
    ipsec_tunnel = nic.src_ipsec_tunnels.first

    sshable = strand.stack.last["dir"] == "out" ? ipsec_tunnel.src_nic.vm.vm_host.sshable : ipsec_tunnel.dst_nic.vm.vm_host.sshable
    target_nic = strand.stack.last["dir"] == "out" ? ipsec_tunnel.src_nic : ipsec_tunnel.dst_nic
    sshable.cmd("sudo ip -n #{ipsec_tunnel.vm_name(target_nic)} xfrm state add " \
      "src #{subdivide_network(ipsec_tunnel.src_nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{new_spi} reqid #{new_reqid} mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{new_key} 128 " \
      "#{is_ipv6 ? "" : "sel src 0.0.0.0/0 dst 0.0.0.0/0"}")

    hop :setup_policy
  end

  def setup_policy
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    is_ipv6 = strand.stack.last["ipv6"]
    new_spi = is_ipv6 ? strand.stack.last["new_spi6"] : strand.stack.last["new_spi4"]
    new_reqid = strand.stack.last["new_reqid"]
    dir = strand.stack.last["dir"]

    src = is_ipv6 ? nic.private_ipv6 : nic.private_ipv4
    dst = is_ipv6 ? ipsec_tunnel.dst_nic.private_ipv6 : ipsec_tunnel.dst_nic.private_ipv4

    sshable = dir == "out" ? ipsec_tunnel.src_nic.vm.vm_host.sshable : ipsec_tunnel.dst_nic.vm.vm_host.sshable
    target_nic = strand.stack.last["dir"] == "out" ? ipsec_tunnel.src_nic : ipsec_tunnel.dst_nic

    sshable.cmd("sudo ip -n #{ipsec_tunnel.vm_name(target_nic)} xfrm policy update " \
      "src #{src} dst #{dst} dir #{dir} " \
      "tmpl src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "spi #{new_spi} proto esp reqid #{new_reqid} mode tunnel")

    pop "new state and policies are set up"
  end

  def drop_old_states
    ipsec_tunnel = nic.src_ipsec_tunnels.first
    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi4"]}")

    ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi4"]}")

    ipsec_tunnel.cmd_src_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.src_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi6"]}")

    ipsec_tunnel.cmd_dst_nic("sudo ip -n #{ipsec_tunnel.vm_name(ipsec_tunnel.dst_nic)} xfrm state delete " \
      "src #{subdivide_network(nic.vm.ephemeral_net6).network} " \
      "dst #{subdivide_network(ipsec_tunnel.dst_nic.vm.ephemeral_net6).network} " \
      "proto esp spi #{strand.stack.last["old_spi6"]}")

    pop "rekeying is complete"
  end

  def subdivide_network(net)
    prefix = net.netmask.prefix_len + 1
    halved = net.resize(prefix)
    halved.next_sib
  end
end
