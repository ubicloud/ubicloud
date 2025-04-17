# frozen_string_literal: true

require "digest"
require "excon"
require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceRouterReplicaNexus < Prog::Base
  subject_is :inference_router_replica

  extend Forwardable
  def_delegators :inference_router_replica, :vm, :inference_router, :load_balancer_vm_port

  def self.assemble(inference_router_id)
    ubid = InferenceRouterReplica.generate_ubid
    DB.transaction do
      inference_router = InferenceRouter[inference_router_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.inference_endpoint_service_project_id,
        sshable_unix_user: "ubi",
        location_id: inference_router.location_id,
        name: ubid.to_s,
        size: "standard-2",
        boot_image: "ubuntu-noble",
        private_subnet_id: inference_router.load_balancer.private_subnet.id,
        enable_ip4: true
      )

      inference_router.load_balancer.add_vm(vm_st.subject)

      replica = InferenceRouterReplica.create(
        inference_router_id: inference_router_id,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Ai::InferenceRouterReplicaNexus", label: "start") { _1.id = replica.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the inference router replica"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline("wait", 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "inference_router", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_setup if leaf?
    donate
  end

  label def setup
    update_config

    asset_name = Config.inference_router_asset_name
    asset_url = Config.inference_router_asset_url
    workdir = "/ir/workdir"

    vm.sshable.cmd("sudo useradd --system --no-create-home --shell /usr/sbin/nologin inference-router")
    vm.sshable.cmd("sudo chown -R inference-router:inference-router #{workdir}")
    vm.sshable.cmd("sudo wget -O #{workdir}/#{asset_name}.tar.gz #{asset_url}")
    vm.sshable.cmd("sudo tar -xzf #{workdir}/#{asset_name}.tar.gz -C #{workdir}")
    write_inference_router_service(asset_name, workdir)
    vm.sshable.cmd("sudo systemctl daemon-reload")
    vm.sshable.cmd("sudo systemctl enable --now inference-router")

    hop_wait_router_up
  end

  def write_inference_router_service(asset_name, workdir)
    service_definition = <<~SERVICE
      [Unit]
      Description=Inference Router
      After=network.target
  
      [Service]
      Type=simple
      User=inference-router
      Group=inference-router
      WorkingDirectory=#{workdir}
      Environment=RUST_BACKTRACE=1
      Environment=RUST_LOG=INFO
      ExecStart=#{workdir}/#{asset_name}/inference-router -c=#{workdir}/config.json
      Restart=always
      RestartSec=5
      StandardOutput=journal
      StandardError=journal
  
      # File system and device restrictions
      ReadOnlyPaths=/
      ReadWritePaths=/ie/workdir
      PrivateTmp=yes
      PrivateMounts=yes
  
      # User management
      SupplementaryGroups=
  
      # Kernel and system protections
      ProtectKernelTunables=yes
      ProtectKernelModules=yes
      ProtectKernelLogs=yes
      ProtectClock=yes
      ProtectHostname=yes
      ProtectControlGroups=yes
  
      # Execution environment restrictions
      NoNewPrivileges=yes
      RestrictNamespaces=yes
      RestrictRealtime=yes
      RestrictSUIDSGID=yes
      LockPersonality=yes
  
      # Network restrictions
      PrivateNetwork=no
  
      # Additional hardening
      KeyringMode=private
      ProtectHome=yes
      DynamicUser=yes
      PrivateUsers=yes
      CapabilityBoundingSet=
      SystemCallFilter=@system-service
      SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @raw-io @reboot @swap
      SystemCallArchitectures=native
      ProtectSystem=strict
      DeviceAllow=
      MemoryDenyWriteExecute=true
      RemoveIPC=true
      UMask=0077
  
      # Resource limits
      LimitNOFILE=65536
  
      [Install]
      WantedBy=multi-user.target
    SERVICE

    vm.sshable.cmd <<~CMD
      sudo tee /etc/systemd/system/inference-router.service > /dev/null << 'EOF'
      #{service_definition}
      EOF
    CMD
  end

  label def wait_router_up
    hop_wait if available?

    nap 5
  end

  label def wait
    hop_unavailable unless available?
    ping_inference_router

    nap 120
  end

  label def destroy
    decr_destroy

    resolve_page
    strand.children.each { _1.destroy }
    inference_router.load_balancer.evacuate_vm(vm)
    inference_router.load_balancer.remove_vm(vm)
    vm.incr_destroy
    inference_router_replica.destroy

    pop "inference router replica is deleted"
  end

  label def unavailable
    if available?
      resolve_page
      hop_wait
    end

    create_page unless inference_router.maintenance_set?
    nap 30
  end

  def available?
    load_balancer_vm_port.reload.state == "up"
  end

  def create_page
    extra_data = {
      inference_router_ubid: inference_router.ubid,
      inference_router_location: inference_router.location.name,
      inference_router_name: inference_router.name,
      inference_router_replica_count: inference_router.replica_count,
      load_balancer_ubid: inference_router.load_balancer.ubid,
      private_subnet_ubid: inference_router.load_balancer.private_subnet.ubid,
      replica_ubid: inference_router_replica.ubid,
      vm_ubid: vm.ubid,
      vm_ip: vm.sshable.host,
      vm_host_ubid: vm.vm_host.ubid,
      vm_host_ip: vm.vm_host.sshable.host
    }
    Prog::PageNexus.assemble("Replica #{inference_router_replica.ubid.to_s[0..7]} of inference router #{inference_router.name} is unavailable",
      ["InferenceRouterReplicaUnavailable", inference_router_replica.ubid],
      inference_router_replica.ubid, severity: "warning", extra_data:)
  end

  def resolve_page
    Page.from_tag_parts("InferenceRouterReplicaUnavailable", inference_router_replica.ubid)&.incr_resolve
  end

  def update_config
    api_key_ds = DB[:api_key].where(
      owner_table: "project",
      used_for: "inference_endpoint",
      is_valid: true,
      owner_id: Sequel[:project][:id]
    ).exists

    eligible_projects_ds = Project.where(api_key_ds).order(:id)
    free_quota_exhausted_projects_ds = FreeQuota.get_exhausted_projects("inference-tokens")
    eligible_projects_ds = eligible_projects_ds
      .exclude(billing_info_id: nil, credit: 0.0, id: free_quota_exhausted_projects_ds)

    eligible_projects = eligible_projects_ds.all
      .select(&:active?)
      .map do
      {
        ubid: _1.ubid,
        api_keys: _1.api_keys
          .select { |k| k.used_for == "inference_endpoint" && k.is_valid }
          .sort_by { |k| k.id }
          .map { |k| Digest::SHA2.hexdigest(k.key) }
      }
    end

    targets = InferenceRouterTarget.order(:created_at).all.group_by(&:model_name)
    routes = targets.map do |model_name, targets_for_model|
      model = Option.ai_model_for_name(model_name)
      {
        model_name: model_name,
        project_inflight_limit: model["project_inflight_limit"] || 100,
        project_prompt_tps_limit: model["project_prompt_tps_limit"] || 10000,
        project_completion_tps_limit: model["max_project_completion_tps"] || 10000,
        endpoints: targets_for_model
          .group_by { |target| target.priority }
          .sort_by { |priority, _| priority }
          .map do |_, targets|
            targets.map do |target|
              target.values.slice(:host, :inflight_limit).merge(
                id: target.name,
                api_key: target.api_key # Decrypts the API key.
              ).merge(target.tags)
            end
          end
      }
    end
    new_config = {
      basic: {},
      certificate: {
        cert: inference_router.load_balancer.active_cert.cert,
        key: OpenSSL::PKey.read(inference_router.load_balancer.active_cert.csr_key).to_pem
      },
      health_check: {
        check_frequency: "10s",
        consecutive_success: 2,
        consecutive_failure: 2
      },
      servers: [{
        name: "main-server",
        addr: "0.0.0.0:8443,::1:8443",
        locations: ["inference", "up"],
        threads: 0,
        prometheus_metrics: "/metrics"
      }, {
        name: "admin-server",
        addr: "0.0.0.0:8080,::1:8080",
        locations: ["usage"],
        threads: 1
      }],
      locations: [
        {name: "up", path: "^/up$", app: "up"},
        {name: "inference", path: "^/v1/(chat/)?completions$", app: "inference"},
        {name: "usage", path: "^/usage$", app: "usage"}
      ],
      projects: eligible_projects,
      routes: routes
    }
    new_config_json = JSON.generate(new_config)
    new_md5 = Digest::MD5.hexdigest(new_config_json)
    config_path = "/ir/workdir/config.json"
    current_md5 = vm.sshable.cmd("md5sum #{config_path} | awk '{ print $1 }'").strip
    if current_md5 != new_md5
      vm.sshable.cmd("sudo mkdir -p /ir/workdir && sudo tee #{config_path} > /dev/null", stdin: new_config_json)
      vm.sshable.cmd("sudo pkill -f -HUP inference-router")
      Clog.emit("Configuration updated successfully.")
    end
  end

  # pushes latest config to inference gateway and collects billing information
  def ping_inference_router
    update_config
    usage_response = vm.sshable.cmd("curl -k https://localhost:8080/usage")
    project_usage = JSON.parse(usage_response)
    Clog.emit("Successfully pinged inference router.") { {inference_router: inference_router.ubid, replica: inference_router_replica.ubid, project_usage: project_usage} }
    update_billing_records(project_usage, "input", "prompt_token_count")
    update_billing_records(project_usage, "output", "completion_token_count")
  end

  def update_billing_records(project_usage, token_type, usage_key)
    begin_time = Date.today.to_time
    end_time = (Date.today + 1).to_time

    project_usage.each do |usage|
      resource_family = "#{usage["model_name"]}-#{token_type}"
      rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
      next if rate["unit_price"].zero?
      rate_id = rate["id"]
      tokens = usage[usage_key]
      next if tokens.zero?
      project = Project.from_ubid(usage["ubid"])

      begin
        today_record = BillingRecord
          .where(project_id: project.id, resource_id: inference_router.id, billing_rate_id: rate_id)
          .where { Sequel.pg_range(_1.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
          .first

        if today_record
          today_record.this.update(amount: Sequel[:amount] + tokens)
        else
          BillingRecord.create_with_id(
            project_id: project.id,
            resource_id: inference_router.id,
            resource_name: "#{resource_family} #{begin_time.strftime("%Y-%m-%d")}",
            billing_rate_id: rate_id,
            span: Sequel.pg_range(begin_time...end_time),
            amount: tokens
          )
        end
      rescue Sequel::Error => ex
        Clog.emit("Failed to update billing record") { {billing_record_update_error: {project_ubid: project.ubid, replica_ubid: inference_router_replica.ubid, tokens: tokens, exception: Util.exception_to_hash(ex)}} }
      end
    end
  end
end
