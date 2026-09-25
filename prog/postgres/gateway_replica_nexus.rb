# frozen_string_literal: true

# One gateway VM, deployed the way the inference router is: a compiled binary
# fetched by tag, a hardened unit, and a config file pushed and diffed.
class Prog::Postgres::GatewayReplicaNexus < Prog::Base
  subject_is :postgres_gateway_replica

  WAIT_SECONDS = 60
  WORKDIR = "/postgres-gateway"

  def self.assemble(postgres_gateway_id)
    gateway = PostgresGateway[postgres_gateway_id]
    fail "no such gateway" unless gateway

    DB.transaction do
      ubid = PostgresGatewayReplica.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.ember_service_project_id,
        sshable_unix_user: "ubi",
        location_id: gateway.location_id,
        name: ubid.to_s,
        size: "standard-2",
        boot_image: "ubuntu-noble",
        private_subnet_id: gateway.private_subnet_id,
        enable_ip4: true,
      )
      replica = PostgresGatewayReplica.create_with_id(
        ubid.to_uuid, postgres_gateway_id: gateway.id, vm_id: vm_st.id, state: "creating",
      )
      Strand.create_with_id(replica, prog: "Postgres::GatewayReplicaNexus", label: "start")
      replica
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    register_deadline("wait", 15 * 60)
    hop_setup_tunnel
  end

  # The gateway end of the IPsec mesh. It is terminated in the VM's namespace
  # on its host, the way a private subnet's tunnels are, so nothing runs
  # inside the VM for it. Everything past the gateway travels inside it,
  # which is what lets the ember speak plain PostgreSQL and so keeps SCRAM
  # channel binding working for the client.
  label def setup_tunnel
    EmberTunnel.ensure_keys(postgres_gateway_replica)
    EmberTunnel.push(postgres_gateway_replica)
    # The hosts cannot answer until they have this replica as a peer.
    postgres_gateway.incr_reconfigure
    hop_setup
  end

  # Idempotent, and re-entered on reconfigure: everything here is written
  # rather than appended, and restarting the gateway drops connections the
  # load balancer will have already moved elsewhere.
  label def setup
    sshable.cmd("sudo mkdir -p :dir", dir: WORKDIR)
    sshable.cmd("id -u postgres-gateway >/dev/null 2>&1 || " \
                "sudo useradd --system --no-create-home --shell /usr/sbin/nologin postgres-gateway")
    install_binary
    write_certificates
    write_unit
    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable postgres-gateway")
    sshable.cmd("sudo systemctl restart postgres-gateway")
    hop_wait_healthy
  end

  label def wait_healthy
    output = sshable.cmd("curl -fsS --max-time 5 http://127.0.0.1:8453/health || true")
    if output.include?("\"ok\":true")
      # Into the load balancer only once it answers: the fleet's front door is
      # the load balancer, and a member that is not serving yet would take a
      # share of the connections and drop them.
      join_load_balancer
      postgres_gateway_replica.update(state: "running")
      postgres_gateway.incr_reconfigure
      hop_wait
    end
    nap 5
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    # An ember host has joined or left the location, or the fleet's
    # configuration has moved on: the wildcard certificate renews every sixty
    # days and the control plane's address can change, and a replica that
    # only ever read them at setup would run on the old ones until it was
    # replaced.
    when_reconfigure_set? do
      decr_reconfigure
      EmberTunnel.push(postgres_gateway_replica)
      hop_setup
    end

    hop_rekey_tunnel if EmberTunnel.rekey_due?(postgres_gateway_replica)
    EmberTunnel.push(postgres_gateway_replica) if EmberTunnel.reapply_due?(postgres_gateway_replica)

    when_drain_set? do
      decr_drain
      postgres_gateway_replica.update(state: "draining")
      # Out of the load balancer first: existing sessions finish, new ones
      # land on another replica, and only then does the process stop.
      postgres_gateway.load_balancer&.evacuate_vm(vm)
      sshable.cmd("sudo systemctl stop postgres-gateway")
      hop_wait
    end

    nap WAIT_SECONDS
  end

  # A peer that is down is skipped rather than waited for, but one that is up
  # and cannot be reached holds the rekey where it is until it can be.
  label def rekey_tunnel
    EmberTunnel.rekey(postgres_gateway_replica)
    hop_wait
  rescue EmberTunnel::PushFailed => e
    Clog.emit("gateway tunnel rekey waiting", {gateway_replica_rekey: {replica: postgres_gateway_replica.ubid, error: e.message}})
    nap 30
  end

  label def destroy
    decr_destroy
    DB.transaction do
      postgres_gateway.load_balancer&.detach_vm(vm)
      vm.incr_destroy
      postgres_gateway_replica.destroy
      # Its tunnels go from every host on their next push.
      postgres_gateway.incr_reconfigure
    end
    pop "gateway replica destroyed"
  end

  def vm = postgres_gateway_replica.vm

  def sshable = vm.sshable

  def postgres_gateway = postgres_gateway_replica.postgres_gateway

  def join_load_balancer
    lb = postgres_gateway.load_balancer
    return if lb.nil? || lb.vms.any? { it.id == vm.id }
    lb.add_vm(vm)
  end

  def install_binary
    # A deployment that does not take its binaries from the gateway's GitHub
    # releases -- a development environment, or an air-gapped one -- points
    # this at its own tarball instead.
    url = Config.postgres_gateway_binary_url || release_url
    sshable.cmd("sudo curl -fsSL -o :dir/postgres-gateway.tar.gz :url", dir: WORKDIR, url:)
    sshable.cmd("sudo tar -xzf :dir/postgres-gateway.tar.gz -C :dir", dir: WORKDIR)
  end

  def release_url
    tag = Config.postgres_gateway_release_tag
    # The tag is postgres-gateway/vX.Y.Z; the asset is named for the version
    # alone, because a release asset's name cannot contain a slash.
    asset = "postgres-gateway-#{tag.split("/").last}-x86_64-unknown-linux-gnu.tar.gz"
    "https://github.com/ubicloud/postgres-gateway/releases/download/#{tag}/#{asset}"
  end

  # The wildcard certificate the clients validate, and the ember root CA.
  # The CA is only needed for routes that opt into a second TLS session; by
  # default the hop is encrypted below PostgreSQL.
  def write_certificates
    cert = postgres_gateway.load_balancer&.active_cert
    # Waiting for the location's wildcard certificate to be issued is an
    # ordinary part of bring-up, not an error to raise once a minute.
    if cert.nil?
      Clog.emit("waiting for the gateway wildcard certificate", {gateway: postgres_gateway.ubid})
      nap 30
    end

    sshable.write_file("#{WORKDIR}/wildcard.crt", cert.cert)
    sshable.write_file("#{WORKDIR}/wildcard.key", OpenSSL::PKey.read(cert.csr_key).to_pem)
    sshable.cmd("sudo chown -R postgres-gateway:postgres-gateway :dir", dir: WORKDIR)
    sshable.cmd("sudo chmod 600 :dir/wildcard.key", dir: WORKDIR)
  end

  def write_unit
    sshable.write_file("/etc/systemd/system/postgres-gateway.service", <<~SERVICE)
      [Unit]
      Description=Postgres Ember gateway
      After=network.target

      [Service]
      Type=simple
      User=postgres-gateway
      Group=postgres-gateway
      Environment=POSTGRES_GATEWAY_TOKEN_SECRET=#{Config.postgres_gateway_token_secret}
      ExecStart=#{WORKDIR}/postgres-gateway \\
        -listen :5432 \\
        -admin-listen 127.0.0.1:8453 \\
        -cert #{WORKDIR}/wildcard.crt \\
        -key #{WORKDIR}/wildcard.key \\
        -control-plane #{Config.postgres_ember_internal_api_url} \\
        -hostname-suffix #{postgres_gateway.hostname_suffix}
      Restart=always
      RestartSec=2
      AmbientCapabilities=CAP_NET_BIND_SERVICE
      NoNewPrivileges=true
      ProtectSystem=strict
      ProtectHome=true
      ReadWritePaths=#{WORKDIR}
      PrivateTmp=true
      RestrictSUIDSGID=yes

      [Install]
      WantedBy=multi-user.target
    SERVICE
  end
end
