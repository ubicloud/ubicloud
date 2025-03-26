# frozen_string_literal: true

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
        storage_volumes: [{size_gib: 20, encrypted: true}],
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
    hop_download_lb_cert if leaf?
    donate
  end

  label def download_lb_cert
    # vm.sshable.cmd(...)
    hop_setup
  end

  label def setup
    # vm.sshable.cmd(...)
    hop_wait_router_up
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

  # pushes latest config to inference gateway and collects billing information
  def ping_inference_router
    api_key_ds = DB[:api_key].where(
      owner_table: "project",
      used_for: "inference_endpoint",
      is_valid: true,
      owner_id: Sequel[:project][:id]
    ).exists

    eligible_projects_ds = Project.where(api_key_ds)
    free_quota_exhausted_projects_ds = FreeQuota.get_exhausted_projects("inference-tokens")
    eligible_projects_ds = eligible_projects_ds
      .exclude(billing_info_id: nil, credit: 0.0, id: free_quota_exhausted_projects_ds)

    eligible_projects = eligible_projects_ds.all
      .select(&:active?)
      .map do
      {
        ubid: _1.ubid,
        api_keys: _1.api_keys.select { |k| k.used_for == "inference_endpoint" && k.is_valid }.map { |k| Digest::SHA2.hexdigest(k.key) }
      }
    end

    body = {
      replica_ubid: inference_router_replica.ubid,
      projects: eligible_projects
    }

    resp = vm.sshable.cmd("sudo curl -m 5 -s -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-router.clover.sock http://localhost/control", stdin: body.to_json)
    project_usage = JSON.parse(resp)["projects"]
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
