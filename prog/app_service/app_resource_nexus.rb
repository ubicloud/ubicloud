# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::AppService::AppResourceNexus < Prog::Base
  subject_is :app_resource

  # The port the app's web process listens on inside the VM; the per-app load
  # balancer forwards to it and TCP-health-checks it.
  WEB_PORT = 8080

  def self.assemble(project_id:, location_id:, name:, repo_url:, branch:)
    Validation.validate_name(name)

    DB.transaction do
      app_resource = AppResource.create(
        project_id:,
        location_id:,
        name:,
        repo_url:,
        branch:,
      )

      # All backing resources live in the Ubicloud-owned app service project.
      firewall = Firewall.create(name: "#{app_resource.ubid}-firewall", location_id:, description: "App Service default firewall", project_id: Config.app_service_project_id)
      private_subnet_id = Prog::Vnet::SubnetNexus.assemble(Config.app_service_project_id, name: "#{app_resource.ubid}-subnet", location_id:, firewall_id: firewall.id).id

      # Allow the control plane to reach servers over SSH, plus the web port the
      # load balancer forwards to and health-checks.
      firewall.replace_firewall_rules(
        Config.control_plane_outbound_cidrs.map { {cidr: it, port_range: Sequel.pg_range(22..22)} } + [
          {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(WEB_PORT..WEB_PORT)},
          {cidr: "::/0", port_range: Sequel.pg_range(WEB_PORT..WEB_PORT)},
        ],
      )

      # Per-app secret store holding config + secrets. App servers read it via
      # their managed identity (granted below in AppServerNexus.assemble).
      secret_store = SecretStore.create(project_id: Config.app_service_project_id, name: app_resource.ubid)

      # Per-app load balancer fronting the web servers, TCP-health-checking the
      # web port. Gets an <app>.<app_service_hostname> subdomain when the app
      # service DNS zone is configured.
      dns_zone = DnsZone[project_id: Config.app_service_project_id, name: Config.app_service_hostname]
      # When the app service DNS zone is configured, serve HTTPS: the LB
      # terminates TLS on 443 using the cert it auto-provisions for the app's
      # <app>.<app_service_hostname> subdomain (DNS-01 in our own zone). Without
      # the zone (dev/test) it's plain HTTP. TCP health check on the web port.
      ports = dns_zone ? [[443, WEB_PORT]] : [[80, WEB_PORT]]
      load_balancer = Prog::Vnet::LoadBalancerNexus.assemble_with_multiple_ports(
        private_subnet_id,
        name: "#{app_resource.ubid}-lb",
        ports:,
        health_check_protocol: "tcp",
        custom_hostname_dns_zone_id: dns_zone&.id,
        custom_hostname_prefix: (app_resource.name if dns_zone),
        cert_enabled: !dns_zone.nil?,
      ).subject

      app_resource.update(private_subnet_id:, secret_store_id: secret_store.id, load_balancer_id: load_balancer.id)

      # Default formation: a single web process. The user scales replicas/size
      # and adds other process types (e.g. worker) via AppResource#scale.
      web_process = AppProcess.create(app_resource_id: app_resource.id, process_type: "web", replica_count: 1, vm_size: AppResource::DEFAULT_VM_SIZE)
      Prog::AppService::AppServerNexus.assemble(web_process)

      Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "start")
    end
  end

  label def start
    app_resource.setup_log_aggregation
    hop_wait_servers
  end

  label def wait_servers
    register_deadline("wait", 10 * 60)

    if Strand.where(id: app_resource.servers_dataset.select(:id)).exclude(label: "wait").empty?
      hop_wait
    end

    nap 10
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_deploy_set? do
      hop_start_deploy
    end

    when_converge_set? do
      hop_converge
    end

    when_provision_database_set? do
      hop_provision_database
    end

    nap 60 * 60 * 24 * 30
  end

  # Finish attaching a database once the Postgres has provisioned its client CA:
  # sign the role's client cert, ask Postgres to create the role, grant the
  # current servers' managed identities access to the cert, and redeploy so the
  # servers pick up the connection. New servers are granted in AppServerNexus.
  label def provision_database
    pg = app_resource.postgres_resource
    nap 10 unless pg&.client_root_cert_1

    app_resource.database_role.issue_certificate!
    pg.incr_configure_roles
    app_resource.servers.each { app_resource.grant_database_access(it.vm_id) }
    app_resource.incr_deploy

    decr_provision_database
    hop_wait
  end

  label def converge
    decr_converge

    recycling = false
    app_resource.processes_dataset.all.each do |process|
      servers = process.servers_dataset.all
      current = servers.reject(&:needs_recycling?)
      stale = servers.select(&:needs_recycling?)

      diff = process.replica_count - current.count
      if diff > 0
        diff.times { Prog::AppService::AppServerNexus.assemble(process) }
      elsif diff < 0
        current.last(-diff).each(&:incr_destroy)
      end

      next if stale.empty?

      # Recycle stale (wrong-size) servers only once enough correctly-sized
      # servers are up, so resizes roll without downtime.
      if current.count >= process.replica_count && current.all? { it.strand.label == "wait" }
        stale.each(&:incr_destroy)
      else
        recycling = true
      end
    end

    nap 10 if recycling
    hop_wait
  end

  label def start_deploy
    decr_deploy

    app_resource.latest_deployment.update(status: "building")
    AppServer.incr_deploy(app_resource.servers_dataset.select(:id))

    hop_wait_deploy
  end

  label def wait_deploy
    register_deadline("wait", 10 * 60)

    deployment = app_resource.latest_deployment
    hop_wait if deployment.status == "failed"

    servers = app_resource.servers_dataset
    if servers.where(current_deployment_id: deployment.id).count == servers.count
      app_resource.deployments_dataset.where(status: "active").update(status: "superseded")
      deployment.update(status: "active")
      app_resource.update(current_deployment_id: deployment.id)
      hop_wait
    end

    nap 10
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    app_resource.load_balancer.incr_destroy
    app_resource.postgres_resource&.incr_destroy

    firewall = app_resource.private_subnet.firewalls_dataset.first(name: "#{app_resource.ubid}-firewall")
    firewall.destroy
    app_resource.private_subnet.incr_destroy

    AppServer.incr_destroy(app_resource.servers_dataset.select(:id))
    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 10 unless app_resource.servers_dataset.empty?

    secret_store = app_resource.secret_store
    app_resource.processes_dataset.destroy
    app_resource.destroy
    AccessControlEntry.where(object_id: secret_store.id).destroy
    secret_store.destroy

    pop "app resource destroyed"
  end
end
