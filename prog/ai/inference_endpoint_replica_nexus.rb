# frozen_string_literal: true

require "excon"
require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointReplicaNexus < Prog::Base
  subject_is :inference_endpoint_replica

  extend Forwardable

  def_delegators :inference_endpoint_replica, :vm, :inference_endpoint, :load_balancer_vm_port

  def self.assemble(inference_endpoint_id)
    DB.transaction do
      ubid = InferenceEndpointReplica.generate_ubid

      inference_endpoint = InferenceEndpoint[inference_endpoint_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.inference_endpoint_service_project_id,
        sshable_unix_user: "ubi",
        location_id: inference_endpoint.location_id,
        name: ubid.to_s,
        size: inference_endpoint.vm_size,
        storage_volumes: inference_endpoint.storage_volumes.map { it.transform_keys(&:to_sym) },
        boot_image: inference_endpoint.boot_image,
        private_subnet_id: inference_endpoint.load_balancer.private_subnet.id,
        enable_ip4: true,
        gpu_count: inference_endpoint.gpu_count
      )

      inference_endpoint.load_balancer.add_vm(vm_st.subject)

      replica = InferenceEndpointReplica.create(
        inference_endpoint_id: inference_endpoint_id,
        vm_id: vm_st.id
      ) { it.id = ubid.to_uuid }

      Strand.create_with_id(replica, prog: "Ai::InferenceEndpointReplicaNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      if !%w[destroy wait_children_destroyed].include?(strand.label)
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the inference endpoint replica"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline("wait", 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "inference_endpoint", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:download_lb_cert)
  end

  label def download_lb_cert
    vm.sshable.cmd("sudo inference_endpoint/bin/download-lb-cert")
    hop_setup_external
  end

  label def setup_external
    case inference_endpoint.engine
    when "runpod"
      if inference_endpoint_replica.external_state["pod_id"]
        if (pod = get_runpod_pod) && pod[:ip] && pod[:port]
          inference_endpoint_replica.update(external_state: pod)
          hop_setup
        end
      else
        inference_endpoint_replica.update(external_state: {"pod_id" => create_runpod_pod})
      end
    else
      hop_setup
    end

    nap 10
  end

  label def setup
    case vm.sshable.cmd("common/bin/daemonizer --check setup")
    when "Succeeded"
      hop_wait_endpoint_up
    when "Failed", "NotStarted"
      params = {
        engine_start_cmd:,
        replica_ubid: inference_endpoint_replica.ubid,
        ssl_crt_path: "/ie/workdir/ssl/ubi_cert.pem",
        ssl_key_path: "/ie/workdir/ssl/ubi_key.pem",
        gateway_port: inference_endpoint.load_balancer.ports.first.dst_port,
        max_requests: inference_endpoint.max_requests
      }
      params_json = JSON.generate(params)
      vm.sshable.cmd("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", stdin: params_json)
    end

    nap 5
  end

  label def wait_endpoint_up
    hop_wait if available?

    nap 5
  end

  label def wait
    hop_unavailable unless available?
    ping_gateway

    nap 120
  end

  label def destroy
    decr_destroy

    resolve_page
    delete_runpod_pod
    Semaphore.incr(strand.children_dataset.select(:id), "destroy")
    hop_wait_children_destroyed
  end

  label def wait_children_destroyed
    reap(nap: 5) do
      inference_endpoint.load_balancer.evacuate_vm(vm)
      inference_endpoint.load_balancer.remove_vm(vm)
      vm.incr_destroy
      inference_endpoint_replica.destroy

      pop "inference endpoint replica is deleted"
    end
  end

  label def unavailable
    if available?
      resolve_page
      hop_wait
    end

    create_page unless inference_endpoint.maintenance_set?
    nap 30
  end

  def available?
    load_balancer_vm_port.reload.state == "up"
  end

  def create_page
    extra_data = {
      inference_endpoint_ubid: inference_endpoint.ubid,
      inference_endpoint_is_public: inference_endpoint.is_public,
      inference_endpoint_location: inference_endpoint.location.name,
      inference_endpoint_name: inference_endpoint.name,
      inference_endpoint_model_name: inference_endpoint.model_name,
      inference_endpoint_replica_count: inference_endpoint.replica_count,
      load_balancer_ubid: inference_endpoint.load_balancer.ubid,
      private_subnet_ubid: inference_endpoint.load_balancer.private_subnet.ubid,
      replica_ubid: inference_endpoint_replica.ubid,
      vm_ubid: vm.ubid,
      vm_ip: vm.sshable.host,
      vm_host_ubid: vm.vm_host.ubid,
      vm_host_ip: vm.vm_host.sshable.host
    }
    Prog::PageNexus.assemble("Replica #{inference_endpoint_replica.ubid.to_s[0..7]} of inference endpoint #{inference_endpoint.name} is unavailable",
      ["InferenceEndpointReplicaUnavailable", inference_endpoint_replica.ubid],
      inference_endpoint_replica.ubid, severity: "warning", extra_data:)
  end

  def resolve_page
    Page.from_tag_parts("InferenceEndpointReplicaUnavailable", inference_endpoint_replica.ubid)&.incr_resolve
  end

  # pushes latest config to inference gateway and collects billing information
  def ping_gateway
    api_key_ds = DB[:api_key]
      .where(owner_table: "project")
      .where(used_for: "inference_endpoint")
      .where(is_valid: true)
      .where(owner_id: Sequel[:project][:id])
      .exists

    eligible_projects_ds = Project.where(api_key_ds)
    free_quota_exhausted_projects_ds = FreeQuota.get_exhausted_projects("inference-tokens")
    eligible_projects_ds = eligible_projects_ds.where(id: inference_endpoint.project.id) unless inference_endpoint.is_public
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
        api_keys: it.api_keys.select { |k| k.used_for == "inference_endpoint" && k.is_valid }.map { |k| Digest::SHA2.hexdigest(k.key) },
        quota_rps: inference_endpoint.max_project_rps,
        quota_tps: inference_endpoint.max_project_tps
      }
    end

    body = {
      replica_ubid: inference_endpoint_replica.ubid,
      public_endpoint: inference_endpoint.is_public,
      projects: eligible_projects
    }

    resp = vm.sshable.cmd("sudo curl -m 10 --no-progress-meter -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-gateway.clover.sock http://localhost/control", stdin: body.to_json)
    project_usage = JSON.parse(resp)["projects"]
    Clog.emit("Successfully pinged inference gateway.") { {inference_endpoint: inference_endpoint.ubid, replica: inference_endpoint_replica.ubid, project_usage: project_usage} }
    update_billing_records(project_usage, "input", "prompt_token_count")
    update_billing_records(project_usage, "output", "completion_token_count")
  end

  def update_billing_records(project_usage, token_type, usage_key)
    resource_family = "#{inference_endpoint.model_name}-#{token_type}"
    rate = BillingRate.from_resource_properties("InferenceTokens", resource_family, "global")
    return if rate["unit_price"].zero?

    rate_id = rate["id"]
    begin_time = Time.now.to_date.to_time
    end_time = begin_time + 24 * 60 * 60

    project_usage.each do |usage|
      tokens = usage[usage_key]
      next if tokens.zero?

      project = Project[id: UBID.to_uuid(usage["ubid"])]

      begin
        today_record = BillingRecord
          .where(project_id: project.id, resource_id: inference_endpoint.id, billing_rate_id: rate_id)
          .where { Sequel.pg_range(it.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
          .first

        if today_record
          today_record.amount = Sequel[:amount] + tokens
          today_record.save_changes(validate: false)
        else
          BillingRecord.create(
            project_id: project.id,
            resource_id: inference_endpoint.id,
            resource_name: "#{resource_family} #{begin_time.strftime("%Y-%m-%d")}",
            billing_rate_id: rate_id,
            span: Sequel.pg_range(begin_time...end_time),
            amount: tokens
          )
        end
      rescue Sequel::Error => ex
        Clog.emit("Failed to update billing record") { {billing_record_update_error: {project_ubid: project.ubid, model_name: inference_endpoint.model_name, replica_ubid: inference_endpoint_replica.ubid, tokens: tokens, exception: Util.exception_to_hash(ex)}} }
      end
    end
  end

  def engine_start_cmd
    case inference_endpoint.engine
    when "vllm"
      env = (inference_endpoint.gpu_count == 0) ? "vllm-cpu" : "vllm"
      "/opt/miniconda/envs/#{env}/bin/vllm serve /ie/models/model --served-model-name #{inference_endpoint.model_name} --disable-log-requests --host 127.0.0.1 #{inference_endpoint.engine_params}"
    when "runpod"
      "ssh -N -L 8000:localhost:8000 root@#{inference_endpoint_replica.external_state["ip"]} -p #{inference_endpoint_replica.external_state["port"]} -i /ie/workdir/.ssh/runpod -o UserKnownHostsFile=/ie/workdir/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
    else
      fail "BUG: unsupported inference engine"
    end
  end

  def create_runpod_pod
    response = Excon.post("https://api.runpod.io/graphql",
      headers: {"content-type" => "application/json", "authorization" => "Bearer #{Config.runpod_api_key}"},
      body: {"query" => "query Pods { myself { pods { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } } }"}.to_json,
      expects: 200)

    pods = JSON.parse(response.body)["data"]["myself"]["pods"]
    pod = pods.find { |pod| pod["name"] == inference_endpoint_replica.ubid }

    return pod["id"] if pod

    ssh_keys = vm.sshable.cmd(<<-CMD) + Config.operator_ssh_public_keys
if ! sudo test -f /ie/workdir/.ssh/runpod; then
  sudo -u ie mkdir -p /ie/workdir/.ssh
  sudo -u ie ssh-keygen -t ed25519 -C #{inference_endpoint_replica.ubid}@ubicloud.com -f /ie/workdir/.ssh/runpod -N '' -q
fi
sudo cat /ie/workdir/.ssh/runpod.pub
    CMD

    vllm_params = "--served-model-name #{inference_endpoint.model_name} --disable-log-requests --host 127.0.0.1 #{inference_endpoint.engine_params}"

    config = inference_endpoint.external_config
    graphql_query = <<~GRAPHQL
      mutation {
        podFindAndDeployOnDemand(
          input: {
            cloudType: ALL
            dataCenterId: "#{config["data_center"]}"
            gpuCount: #{config["gpu_count"]}
            gpuTypeId: "#{config["gpu_type"]}"
            containerDiskInGb: #{config["disk_gib"]}
            minVcpuCount: #{config["min_vcpu_count"]}
            minMemoryInGb: #{config["min_memory_gib"]}
            imageName: "#{config["image_name"]}"
            name: "#{inference_endpoint_replica.ubid}"
            volumeInGb: 0
            ports: "22/tcp"
            env: [
              { key: "HF_TOKEN", value: "#{Config.huggingface_token}" },
              { key: "HF_HUB_ENABLE_HF_TRANSFER", value: "1"},
              { key: "MODEL_PATH", value: "/model"},
              { key: "MODEL_NAME_HF", value: "#{config["model_name_hf"]}"},
              { key: "VLLM_PARAMS", value: "#{vllm_params}"},
              { key: "SSH_KEYS", value: "#{ssh_keys.gsub("\n", "\\n")}" }
            ]
          }
        ) {
          id
          imageName
          env
          machineId
          machine {
            podHostId
          }
        }
      }
    GRAPHQL

    response = Excon.post("https://api.runpod.io/graphql",
      headers: {"content-type" => "application/json", "authorization" => "Bearer #{Config.runpod_api_key}"},
      body: {"query" => graphql_query}.to_json,
      expects: 200)

    JSON.parse(response.body)["data"]["podFindAndDeployOnDemand"]["id"]
  end

  def get_runpod_pod
    pod_id = inference_endpoint_replica.external_state.fetch("pod_id")
    response = Excon.post("https://api.runpod.io/graphql",
      headers: {"content-type" => "application/json", "authorization" => "Bearer #{Config.runpod_api_key}"},
      body: {"query" => "query Pod { pod(input: {podId: \"#{pod_id}\"}) { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } }"}.to_json,
      expects: 200)

    pod = JSON.parse(response.body)["data"]["pod"]
    fail "BUG: pod not found" unless pod
    fail "BUG: unexpected pod id" unless pod_id == pod["id"]

    port = pod["runtime"]["ports"].find { |port| port["type"] == "tcp" && port["isIpPublic"] }

    {
      pod_id: pod["id"],
      ip: port&.fetch("ip"),
      port: port&.fetch("publicPort")
    }
  end

  def delete_runpod_pod
    return unless (pod_id = inference_endpoint_replica.external_state["pod_id"])

    Excon.post("https://api.runpod.io/graphql",
      headers: {"content-type" => "application/json", "authorization" => "Bearer #{Config.runpod_api_key}"},
      body: {"query" => "mutation { podTerminate(input: {podId: \"#{pod_id}\"}) }"}.to_json,
      expects: 200)
    inference_endpoint_replica.update(external_state: "{}")
  end
end
