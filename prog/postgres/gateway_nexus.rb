# frozen_string_literal: true

# One gateway fleet per location (design doc 8.1).
#
# The fleet sits behind the location's TCP load balancer and a wildcard
# certificate, so one DNS record per location covers every ember and no DNS
# change ever happens per ember.
class Prog::Postgres::GatewayNexus < Prog::Base
  subject_is :postgres_gateway
  frame_accessor :pushed_sources

  WAIT_SECONDS = 60

  def self.assemble(location_id, hostname_suffix: nil, replica_count: nil)
    fail "gateway already exists for location" if PostgresGateway[location_id:]

    DB.transaction do
      gateway = PostgresGateway.create(
        location_id:,
        hostname_suffix: hostname_suffix || Config.postgres_gateway_hostname_suffix,
        replica_count: replica_count || Config.postgres_gateway_replica_count,
      )
      Strand.create_with_id(gateway, prog: "Postgres::GatewayNexus", label: "start")
      gateway
    end
  end

  label def start
    register_deadline("wait", 30 * 60)
    project_id = Config.ember_service_project_id
    fail "ember_service_project_id is not configured" unless project_id

    DB.transaction do
      subnet = Prog::Vnet::SubnetNexus.assemble(
        project_id, name: "postgres-gateway-#{postgres_gateway.ubid}",
        location_id: postgres_gateway.location_id,
      ).subject
      postgres_gateway.update(private_subnet_id: subnet.id)
    end
    hop_create_load_balancer
  end

  label def create_load_balancer
    subnet = postgres_gateway.private_subnet
    nap 5 unless subnet.strand.label == "wait"

    DB.transaction do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(
        subnet.id,
        name: "postgres-gateway-#{postgres_gateway.ubid}",
        algorithm: "round_robin",
        # Pure TCP passthrough: the gateway terminates TLS itself, because it
        # has to read SNI to know which ember a connection is for.
        src_port: 5432, dst_port: 5432,
        health_check_endpoint: "/", health_check_protocol: "tcp",
        stack: LoadBalancer::Stack::DUAL,
      ).subject
      postgres_gateway.update(load_balancer_id: lb.id)
    end
    hop_wait_replicas
  end

  label def wait_replicas
    missing = postgres_gateway.replica_count - postgres_gateway.replicas.count
    if missing.positive?
      missing.times { Prog::Postgres::GatewayReplicaNexus.assemble(postgres_gateway.id) }
    end
    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    # A replica that has come or gone changes every host's IPsec peers and the
    # set of addresses embers accept connections from.
    when_reconfigure_set? do
      decr_reconfigure
      hop_push_hosts
    end

    hop_push_hosts if sources_changed?

    hop_wait_replicas if postgres_gateway.replicas.count < postgres_gateway.replica_count

    hop_sync_hosts if ember_host_ids != postgres_gateway.hosts_dataset.select_order_map(:id)

    hop_rekey_hosts if postgres_gateway.hosts.any? { EmberTunnel.rekey_due?(it) }
    postgres_gateway.hosts.each { EmberTunnel.push(it) if EmberTunnel.reapply_due?(it) }

    nap WAIT_SECONDS
  end

  # Peer with every ember host in the location, and stop peering with hosts
  # that no longer take embers. A new host's replicas learn it before its own
  # end is pushed, and that push is what makes the host ready for embers.
  label def sync_hosts
    enabled = ember_host_ids
    postgres_gateway.hosts.reject { enabled.include?(it.id) }.each(&:destroy)
    postgres_gateway.replicas.each(&:incr_reconfigure)

    (enabled - postgres_gateway.hosts_dataset.select_map(:id)).each do |id|
      host = PostgresGatewayHost.create_with_id(id, postgres_gateway_id: postgres_gateway.id)
      EmberTunnel.ensure_keys(host)
      EmberTunnel.push_peers(host)
      EmberTunnel.push(host)
    end
    hop_push_hosts
  rescue EmberTunnel::PushFailed => e
    Clog.emit("gateway host sync waiting", {gateway_host_sync: {gateway: postgres_gateway.ubid, error: e.message}})
    nap 30
  end

  # A peer that is down is skipped rather than waited for, but one that is up
  # and cannot be reached holds the rekey where it is until it can be.
  label def rekey_hosts
    postgres_gateway.hosts.select { EmberTunnel.rekey_due?(it) }.each { EmberTunnel.rekey(it) }
    hop_wait
  rescue EmberTunnel::PushFailed => e
    Clog.emit("gateway host rekey waiting", {gateway_host_rekey: {gateway: postgres_gateway.ubid, error: e.message}})
    nap 30
  end

  # Push every ember host its IPsec peers and the addresses its embers accept
  # connections from, which are the location's gateway replicas.
  label def push_hosts
    sources = postgres_gateway.source_prefixes
    postgres_gateway.hosts.each do |host|
      EmberTunnel.push(host)
      host.vm_host.ember.cmd_json("sudo host/bin/ember ingress-sources", stdin: {"ingress_sources" => sources})
    rescue => e
      Clog.emit("pushing to ember host failed", {gateway_host_push: {host: host.ubid, error: e.message}})
    end
    self.pushed_sources = sources
    hop_wait
  end

  label def destroy
    decr_destroy
    postgres_gateway.replicas.each(&:incr_destroy)
    nap 10 unless postgres_gateway.replicas.empty?

    DB.transaction do
      postgres_gateway.load_balancer&.incr_destroy
      postgres_gateway.private_subnet&.incr_destroy
      postgres_gateway.destroy
    end
    pop "ember gateway destroyed"
  end

  def ember_host_ids
    VmHost.ember_enabled(location_id: postgres_gateway.location_id).select_order_map(:id)
  end

  def sources_changed?
    pushed_sources != postgres_gateway.source_prefixes
  end
end
