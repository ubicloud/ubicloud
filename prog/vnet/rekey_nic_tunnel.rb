# frozen_string_literal: true

class Prog::Vnet::RekeyNicTunnel < Prog::Base
  subject_is :nic

  def before_run
    if nic.destroy_set?
      pop "nic.destroy semaphore is set"
    end
  end

  label def setup_inbound
    nic.dst_ipsec_tunnels.each do |tunnel|
      args = tunnel.src_nic.rekey_payload
      next unless args

      policy = Xfrm.new(nic, tunnel, "fwd")
      policy.create_state
      policy.upsert_policy
    end

    pop "inbound_setup is complete"
  end

  label def setup_outbound
    nic.src_ipsec_tunnels.each do |tunnel|
      args = tunnel.src_nic.rekey_payload
      next unless args

      policy = Xfrm.new(nic, tunnel, "out")
      policy.create_state
      policy.upsert_policy
      policy.create_private_routes
    end

    pop "outbound_setup is complete"
  end

  label def drop_old_state
    if nic.src_ipsec_tunnels.empty? && nic.dst_ipsec_tunnels.empty?
      nic.vm.vm_host.sshable.cmd("sudo ip -n #{nic.vm.inhost_name.shellescape} xfrm state deleteall")
      pop "drop_old_state is complete early"
    end

    new_spis = [nic.rekey_payload["spi4"], nic.rekey_payload["spi6"]]
    new_spis += nic.dst_ipsec_tunnels.map do |tunnel|
      next unless tunnel.src_nic.rekey_payload

      [tunnel.src_nic.rekey_payload["spi4"], tunnel.src_nic.rekey_payload["spi6"]]
    end.flatten

    state_data = nic.vm.vm_host.sshable.cmd("sudo ip -n #{nic.src_ipsec_tunnels.first.vm_name(nic)} xfrm state")

    # Extract SPIs along with src and dst from state data
    states = state_data.scan(/^src (\S+) dst (\S+).*?proto esp spi (0x[0-9a-f]+)/m)

    # Identify which states to drop
    states_to_drop = states.reject { |(_, _, spi)| new_spis.include?(spi) }
    states_to_drop.each do |src, dst, spi|
      nic.vm.vm_host.sshable.cmd("sudo ip -n #{nic.src_ipsec_tunnels.first.vm_name(nic)} xfrm state delete src #{src} dst #{dst} proto esp spi #{spi}")
    end

    pop "drop_old_state is complete"
  end

  class Xfrm
    FORWARD = "fwd"

    def initialize(nic, tunnel, direction)
      @nic = nic
      @tunnel = tunnel
      @namespace = tunnel.vm_name(nic)
      @tmpl_src = subdivide_network(tunnel.src_nic.vm.ephemeral_net6).network
      @tmpl_dst = subdivide_network(tunnel.dst_nic.vm.ephemeral_net6).network
      @reqid = tunnel.src_nic.rekey_payload["reqid"]
      @dir = direction
      @args = tunnel.src_nic.rekey_payload
    end

    def upsert_policy
      apply_policy(@tunnel.src_nic.private_ipv4, @tunnel.dst_nic.private_ipv4)
      apply_policy(@tunnel.src_nic.private_ipv6, @tunnel.dst_nic.private_ipv6)
    end

    def create_state
      create_xfrm_state(@tmpl_src, @tmpl_dst, @args["spi4"], true)
      create_xfrm_state(@tmpl_src, @tmpl_dst, @args["spi6"], false)
    end

    def create_private_routes
      [@tunnel.dst_nic.private_ipv6, @tunnel.dst_nic.private_ipv4].each do |dst_ip|
        @nic.vm.vm_host.sshable.cmd("sudo ip -n #{@namespace} route replace #{dst_ip.to_s.shellescape} dev vethi#{@namespace}")
      end
    end

    private

    def apply_policy(src, dst)
      cmd = policy_exists?(src, dst) ? "update" : "add"
      return if cmd == "update" && @dir == FORWARD

      @nic.vm.vm_host.sshable.cmd(form_command(src, dst, cmd))
    end

    def create_xfrm_state(src, dst, spi, is_ipv4)
      key = @tunnel.src_nic.encryption_key
      begin
        @nic.vm.vm_host.sshable.cmd("sudo -- xargs -I {} -- ip -n #{@namespace} xfrm state add " \
          "src #{src} dst #{dst} proto esp spi #{spi} reqid #{@reqid} mode tunnel " \
          "aead 'rfc4106(gcm(aes))' {} 128 #{"sel src 0.0.0.0/0 dst 0.0.0.0/0" if is_ipv4}", stdin: key)
      rescue Sshable::SshError => e
        raise unless e.stderr.include?("File exists")
      end
    end

    def policy_exists?(src, dst)
      !@nic.vm.vm_host.sshable.cmd(form_command(src, dst, "show")).empty?
    end

    def form_command(src, dst, cmd)
      base = "sudo ip -n #{@namespace} xfrm policy #{cmd} src #{src} dst #{dst} dir #{@dir}"
      tmpl = if cmd == "show"
        ""
      else
        "tmpl src #{@tmpl_src} dst #{@tmpl_dst} proto esp reqid #{(@dir == FORWARD) ? 0 : @reqid} mode tunnel"
      end

      "#{base} #{tmpl}".strip
    end

    def subdivide_network(net)
      prefix = net.netmask.prefix_len + 1
      halved = net.resize(prefix)
      halved.next_sib
    end
  end
end
