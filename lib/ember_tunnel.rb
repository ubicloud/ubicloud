# frozen_string_literal: true

# The IPsec mesh between a location's gateway replicas and its ember hosts.
#
# This carries the encryption for the gateway-to-ember hop. It exists
# because the design's original answer, a second TLS session with a
# per-ember certificate, makes SCRAM channel binding impossible: libpq
# defaults to channel_binding=prefer, binds to the gateway's certificate, and
# the ember verifies against its own.
#
# It is the same IPsec private subnets use: ESP in tunnel mode with keys from
# the control plane and no IKE, set up with ip xfrm. The gateway end is
# terminated in the gateway VM's namespace on its host, with the second half of
# the VM's address block as the tunnel endpoint, exactly as a private subnet's
# tunnels are, so nothing runs inside the gateway VM for it. The ember host end
# is the host's own address. Inside the tunnel, the gateway speaks from the
# guest half of that block to the host's slot block, both of which are routed
# already, so the mesh needs no addresses of its own.
#
# The mesh is replicas times hosts within one location, which is small and
# static, unlike the VM-to-VM mesh the design deliberately avoided.
module EmberTunnel
  module_function

  # Keys are static, so they are rotated from the control plane, daily, the
  # way private subnets rotate theirs.
  REKEY_INTERVAL = 24 * 60 * 60

  # Each end pushes its own view this often as well as on every change, so an
  # end whose kernel lost its tunnels -- a host reboot, a VM restart -- gets
  # them back without anything having to notice.
  REAPPLY_INTERVAL = 10 * 60

  # A private subnet's tunnels can share a gateway VM's namespace, and they
  # draw reqids from 1...100_000; these stay clear of them.
  REQID_RANGE = (100_000...200_000)

  class PushFailed < StandardError; end

  # AES-256-GCM: 32 bytes of key and 4 of salt, as for a private subnet.
  def new_key(outbound:)
    {"spi" => "0x" + SecureRandom.bytes(4).unpack1("H*"),
     "reqid" => SecureRandom.random_number(REQID_RANGE),
     "key" => "0x" + SecureRandom.bytes(36).unpack1("H*"),
     "outbound" => outbound}
  end

  # Both ends of the mesh -- a gateway replica and a gateway's row for an ember
  # host -- carry the same tunnel columns, so either can be handed in.
  def keys(record)
    record.tunnel_keys ? JSON.parse(record.tunnel_keys) : nil
  end

  def save_keys(record, keys, **)
    record.update(tunnel_keys: JSON.generate(keys), **)
  end

  def ensure_keys(record)
    return if record.tunnel_keys
    save_keys(record, {"keys" => [new_key(outbound: true)], "phase" => nil}, tunnel_rekeyed_at: Time.now)
  end

  # Where each end of the mesh lives, and what it speaks from.
  def endpoint(record)
    if record.is_a?(PostgresGatewayReplica)
      vm = record.vm
      net = NetAddr::IPv6Net.parse(vm.ephemeral_net6.to_s)
      halves = net.resize(net.netmask.prefix_len + 1)
      {sshable: vm.vm_host.sshable, netns: vm.inhost_name,
       outer: halves.next_sib.network.to_s, inner: halves.to_s}
    else
      {sshable: record.vm_host.sshable, netns: nil,
       outer: record.vm_host.ip6.to_s, inner: record.vm_host.ember.ip6_block.to_s}
    end
  end

  # A replica's peers are its gateway's ember hosts, and an ember host's are
  # that gateway's replicas. Only ends that have keys are peers yet.
  def peers(record)
    if record.is_a?(PostgresGatewayReplica)
      record.postgres_gateway.hosts
    else
      record.postgres_gateway.replicas
    end.select(&:tunnel_keys)
  end

  # Everything one end's tunnels should be, read from the database after the
  # serial is taken. The host side applies a spec only if its serial is not
  # older than the last one it applied, so of two pushes racing each other the
  # later view wins, and every change to the keys is followed by a push of its
  # own with a serial taken after it committed.
  def spec(record)
    serial = (Time.now.to_r * 1_000_000).to_i
    record.refresh
    ep = endpoint(record)
    outbound = keys(record)["keys"].find { it["outbound"] }
    {
      "serial" => serial,
      "netns" => ep[:netns],
      "self" => {"outer" => ep[:outer], "inner" => ep[:inner],
                 "outbound" => outbound.slice("spi", "reqid", "key")},
      "peers" => peers(record).map do |peer|
        peer_ep = endpoint(peer)
        {"outer" => peer_ep[:outer], "inner" => peer_ep[:inner],
         "keys" => keys(peer)["keys"].map { it.slice("spi", "reqid", "key") }}
      end,
    }
  end

  # The key material goes on stdin, never into a command line.
  def push(record)
    endpoint(record)[:sshable].cmd("sudo host/bin/setup-ember-tunnel", stdin: JSON.generate(spec(record)))
    record.update(tunnel_pushed_at: Time.now)
  end

  def reapply_due?(record)
    return false unless record.tunnel_keys
    record.tunnel_pushed_at.nil? || record.tunnel_pushed_at < Time.now - REAPPLY_INTERVAL
  end

  # Push to every peer that is up. One that is down is skipped rather than
  # holding up a rekey: it pushes its own view, with this end's current keys
  # in it, when it comes back.
  def push_peers(record)
    failed = peers(record).select { live?(it) }.filter_map do |peer|
      push(peer)
      nil
    rescue => e
      Clog.emit("ember tunnel push failed", {ember_tunnel: {peer: peer.ubid, error: e.message}})
      peer.ubid
    end
    raise PushFailed, "could not reach #{failed.join(", ")}" unless failed.empty?
  end

  def live?(record)
    record.is_a?(PostgresGatewayReplica) ? record.running? : record.vm_host.ember.available?
  end

  def rekey_due?(record)
    keys = keys(record)
    return false unless keys
    !keys["phase"].nil? || record.tunnel_rekeyed_at.nil? || record.tunnel_rekeyed_at < Time.now - REKEY_INTERVAL
  end

  # Rotate one end's key without dropping a packet, in the three steps a
  # private subnet uses: every peer learns to accept the new key, then this
  # end sends with it, then every peer forgets the old one. The phase is saved
  # before each push, so a rekey that fails partway resumes where it stopped.
  def rekey(record)
    keys = keys(record)
    if keys["phase"].nil?
      keys["keys"] << new_key(outbound: false)
      keys["phase"] = "adding"
      save_keys(record, keys)
    end

    if keys["phase"] == "adding"
      push_peers(record)
      keys["keys"].each_with_index { |key, i| key["outbound"] = i == keys["keys"].size - 1 }
      keys["phase"] = "switching"
      save_keys(record, keys)
    end

    if keys["phase"] == "switching"
      push(record)
      keys["keys"].select! { it["outbound"] }
      keys["phase"] = "dropping"
      save_keys(record, keys)
    end

    push_peers(record)
    keys["phase"] = nil
    save_keys(record, keys, tunnel_rekeyed_at: Time.now)
  end
end
