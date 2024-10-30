# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointReplicaNexus < Prog::Base
  subject_is :inference_endpoint_replica

  extend Forwardable
  def_delegators :inference_endpoint_replica, :vm, :inference_endpoint

  semaphore :destroy

  def self.assemble(inference_endpoint_id)
    DB.transaction do
      ubid = InferenceEndpointReplica.generate_ubid

      inference_endpoint = InferenceEndpoint[inference_endpoint_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.inference_endpoint_service_project_id,
        location: inference_endpoint.location,
        name: ubid.to_s,
        size: inference_endpoint.vm_size,
        storage_volumes: inference_endpoint.storage_volumes.map { _1.transform_keys(&:to_sym) },
        boot_image: inference_endpoint.boot_image,
        private_subnet_id: inference_endpoint.load_balancer.private_subnet.id,
        enable_ip4: true,
        gpu_count: inference_endpoint.gpu_count
      )

      inference_endpoint.load_balancer.add_vm(vm_st.subject)

      replica = InferenceEndpointReplica.create(
        inference_endpoint_id: inference_endpoint_id,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Ai::InferenceEndpointReplicaNexus", label: "start") { _1.id = replica.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
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
    register_deadline(:wait, 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "inference_endpoint", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_download_lb_cert if leaf?
    donate
  end

  label def download_lb_cert
    vm.sshable.cmd("sudo inference_endpoint/bin/download-lb-cert")
    hop_setup
  end

  label def setup
    case vm.sshable.cmd("common/bin/daemonizer --check setup")
    when "Succeeded"
      hop_wait_endpoint_up
    when "Failed", "NotStarted"
      params = {
        inference_engine: inference_endpoint.engine,
        inference_engine_params: inference_endpoint.engine_params,
        model: inference_endpoint.model_name,
        replica_ubid: inference_endpoint_replica.ubid,
        ssl_crt_path: "/ie/workdir/ssl/ubi_cert.pem",
        ssl_key_path: "/ie/workdir/ssl/ubi_key.pem",
        gateway_port: inference_endpoint.load_balancer.dst_port
      }
      params_json = JSON.generate(params)
      vm.sshable.cmd("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", stdin: params_json)
    end

    nap 5
  end

  label def wait_endpoint_up
    if inference_endpoint.load_balancer.reload.active_vms.map { _1.id }.include? vm.id
      hop_wait
    end

    nap 5
  end

  label def wait
    ping_gateway

    nap 60
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    inference_endpoint.load_balancer.evacuate_vm(vm)
    inference_endpoint.load_balancer.remove_vm(vm)
    vm.incr_destroy
    inference_endpoint_replica.destroy

    pop "inference endpoint replica is deleted"
  end

  # pushes latest config to inference gateway and collects billing information
  def ping_gateway
    projects = if inference_endpoint.is_public
      Project.where(DB[:api_key]
      .where(owner_table: "project")
      .where(used_for: "inference_endpoint")
      .where(is_valid: true)
      .where(owner_id: Sequel[:project][:id]).exists)
        .reject { |pj| pj.accounts.any? { |ac| !ac.suspended_at.nil? } }
        .map do
        {
          ubid: _1.ubid,
          api_keys: _1.api_keys.select { |k| k.used_for == "inference_endpoint" && k.is_valid }.map { |k| Digest::SHA2.hexdigest(k.key) },
          quota_rps: 50.0,
          quota_tps: 5000.0
        }
      end
    else
      [{
        ubid: inference_endpoint.project.ubid,
        api_keys: inference_endpoint.api_keys.select(&:is_valid).map { |k| Digest::SHA2.hexdigest(k.key) },
        quota_rps: 100.0,
        quota_tps: 1000000.0
      }]
    end
    body = {
      replica_ubid: inference_endpoint_replica.ubid,
      public_endpoint: inference_endpoint.is_public,
      projects: projects
    }

    resp = vm.sshable.cmd("sudo curl -s -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-gateway.clover.sock http://localhost/control", stdin: body.to_json)
    project_usage = JSON.parse(resp)["projects"]
    Clog.emit("Successfully pinged inference gateway.") { {inference_endpoint: inference_endpoint.ubid, replica: inference_endpoint_replica.ubid, project_usage: project_usage} }
    update_billing_records(project_usage)
  end

  def update_billing_records(project_usage)
    rate = BillingRate.from_resource_properties("InferenceTokens", inference_endpoint.model_name, "global")
    return if rate["unit_price"].zero?
    rate_id = rate["id"]
    begin_time = Time.now.to_date.to_time
    end_time = begin_time + 24 * 60 * 60

    project_usage.each do |usage|
      tokens = usage["prompt_token_count"] + usage["completion_token_count"]
      next if tokens.zero?
      project = Project.from_ubid(usage["ubid"])

      begin
        today_record = BillingRecord
          .where(project_id: project.id, resource_id: inference_endpoint.id, billing_rate_id: rate_id)
          .where { Sequel.pg_range(_1.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
          .first

        if today_record
          today_record.amount = Sequel[:amount] + tokens
          today_record.save_changes(validate: false)
        else
          BillingRecord.create_with_id(
            project_id: project.id,
            resource_id: inference_endpoint.id,
            resource_name: "Inference tokens #{inference_endpoint.model_name} #{begin_time.strftime("%Y-%m-%d")}",
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
end
