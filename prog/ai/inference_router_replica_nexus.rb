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
        size: inference_router.vm_size,
        boot_image: "ubuntu-noble",
        private_subnet_id: inference_router.load_balancer.private_subnet.id,
        enable_ip4: true
      )

      inference_router.load_balancer.add_vm(vm_st.subject)

      replica = InferenceRouterReplica.create(
        inference_router_id: inference_router_id,
        vm_id: vm_st.id
      ) { it.id = ubid.to_uuid }

      Strand.create_with_id(replica.id, prog: "Ai::InferenceRouterReplicaNexus", label: "start")
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
    reap(:setup)
  end

  label def setup
    update_config

    workdir = "/ir/workdir"
    release_tag = Config.inference_router_release_tag
    access_token = Config.inference_router_access_token
    asset_name = "inference-router-#{release_tag}-x86_64-unknown-linux-gnu"
    vm.sshable.cmd("id -u inference-router >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin inference-router")
    vm.sshable.cmd("sudo chown -R inference-router:inference-router #{workdir}")
    vm.sshable.cmd("sudo wget -O #{workdir}/fetch_linux_amd64 https://github.com/gruntwork-io/fetch/releases/download/v0.4.6/fetch_linux_amd64")
    vm.sshable.cmd("sudo chmod +x #{workdir}/fetch_linux_amd64")
    vm.sshable.cmd("sudo #{workdir}/fetch_linux_amd64 --github-oauth-token=\"#{access_token}\" --repo=\"https://github.com/ubicloud/inference-router\" --tag=\"#{release_tag}\" --release-asset=\"inference-router-*\" #{workdir}/")
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
      KillSignal=SIGINT
      Restart=always
      RestartSec=5
      StandardOutput=journal
      StandardError=journal
  
      # File system and device restrictions
      ReadOnlyPaths=/
      ReadWritePaths=/ir/workdir
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
    strand.children.each { it.destroy }
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
    valid_payment_method_ds = DB[:payment_method]
      .where(fraud: false)
      .select_group(:billing_info_id)
      .select_append { Sequel.as(Sequel.lit("1"), :valid_payment_method) }
    eligible_projects_ds = eligible_projects_ds
      .left_outer_join(valid_payment_method_ds, [:billing_info_id])
      .exclude(valid_payment_method: nil, credit: 0.0, id: free_quota_exhausted_projects_ds)

    eligible_projects = eligible_projects_ds.all
      .select(&:active?)
      .map do
      {
        ubid: it.ubid,
        api_keys: it.api_keys
          .select { |k| k.used_for == "inference_endpoint" && k.is_valid }
          .sort_by { |k| k.id }
          .map { |k| Digest::SHA2.hexdigest(k.key) }
      }
    end

    targets = InferenceRouterTarget.order(:created_at).all.group_by(&:inference_router_model)
    routes = targets.map do |inference_router_model, targets_for_model|
      {
        model_name: inference_router_model.model_name,
        project_inflight_limit: inference_router_model.project_inflight_limit,
        project_prompt_tps_limit: inference_router_model.project_prompt_tps_limit,
        project_completion_tps_limit: inference_router_model.project_completion_tps_limit,
        endpoints: targets_for_model
          .group_by { |target| target.priority }
          .sort_by { |priority, _| priority }
          .map do |_, targets|
            targets
              .select { |target| target.enabled }
              .map do |target|
              target.values.slice(:host, :inflight_limit)
                .merge(id: target.name, api_key: target.api_key)
                .merge(target.extra_configs)
            end
          end
      }
    end
    new_config = {
      certificate: {
        cert: inference_router.load_balancer.active_cert.cert,
        key: OpenSSL::PKey.read(inference_router.load_balancer.active_cert.csr_key).to_pem
      },
      projects: eligible_projects,
      routes: routes
    }
    new_config = new_config.merge(JSON.parse(File.read("config/inference_router_config.json")))
    new_config_json = JSON.generate(new_config)
    new_md5 = Digest::MD5.hexdigest(new_config_json)
    config_path = "/ir/workdir/config.json"
    current_md5 = vm.sshable.cmd("md5sum #{config_path} | awk '{ print $1 }'").strip
    if current_md5 != new_md5
      # print("new_md5: #{new_md5}, current_md5: #{current_md5}\n") # Uncomment for obtaining md5 for testing.
      vm.sshable.cmd("sudo mkdir -p /ir/workdir && sudo tee #{config_path} > /dev/null", stdin: new_config_json)
      vm.sshable.cmd("sudo pkill -f -HUP inference-router")
      Clog.emit("Configuration updated successfully.")
    end
  end

  # pushes latest config to inference router and collects billing information
  def ping_inference_router
    update_config
    usage_response = vm.sshable.cmd("curl -k -m 10 --no-progress-meter https://localhost:8080/usage")
    project_usage = JSON.parse(usage_response)
    Clog.emit("Successfully pinged inference router.") { {inference_router: inference_router.ubid, replica: inference_router_replica.ubid, project_usage: project_usage} }
    update_billing_records(project_usage, "prompt_billing_resource", "prompt_token_count")
    update_billing_records(project_usage, "completion_billing_resource", "completion_token_count")
  end

  def update_billing_records(project_usage, billing_resource_key, usage_key)
    begin_time = Date.today.to_time
    end_time = (Date.today + 1).to_time

    project_usage.each do |usage|
      model = InferenceRouterModel.from_model_name(usage["model_name"])
      resource_family = model[billing_resource_key.to_sym]
      rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
      next if rate["unit_price"].zero?
      rate_id = rate["id"]
      tokens = usage[usage_key]
      next if tokens.zero?
      project = Project[id: UBID.to_uuid(usage["ubid"])]

      begin
        today_record = BillingRecord
          .where(project_id: project.id, resource_id: inference_router.id, billing_rate_id: rate_id)
          .where { Sequel.pg_range(it.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
          .first

        if today_record
          today_record.this.update(amount: Sequel[:amount] + tokens)
        else
          BillingRecord.create(
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
