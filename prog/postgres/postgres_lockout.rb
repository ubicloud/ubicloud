# frozen_string_literal: true

require "google/cloud/compute/v1"
require "googleauth"

class Prog::Postgres::PostgresLockout < Prog::Base
  include GcpLro

  GCP_BUDGET = 60
  GCP_ERRORS = [
    Google::Cloud::Error, Google::Auth::CredentialsError,
    Signet::AuthorizationError, Signet::ParseError, Signet::UnexpectedStatusError,
  ].freeze

  subject_is :postgres_server
  frame_reader :mechanism
  frame_accessor :gcp_deadline, :deny_rule_ops

  def before_run
    super
    pop_gcp_failed("deadline passed") if gcp_deadline && Time.now.to_i > gcp_deadline
  end

  label def start
    if mechanism == "firewall_reset"
      self.gcp_deadline = Time.now.to_i + GCP_BUDGET
      hop_add_deny_rules
    end

    send("lockout_with_#{mechanism}")
    pop_succeeded
  rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError, Aws::EC2::Errors::ServiceError
    pop "lockout_failed"
  end

  label def add_deny_rules
    client = credential.lockout_network_firewall_policies_client
    rules = client.get(project: gcp_project_id, firewall_policy:).rules
    used = rules.to_set(&:priority)
    present = rules.to_set(&:rule_name)

    self.deny_rule_ops = deny_rules.reject { present.include?(it.rule_name) }.map do |rule|
      rule.priority = GcpFirewallPolicy::FENCE_PRIORITIES.find { !used.include?(it) }
      used << rule.priority
      client.add_rule(project: gcp_project_id, firewall_policy:, firewall_policy_rule_resource: rule).name
    end
    hop_wait_deny_rules
  rescue Google::Cloud::InvalidArgumentError => e
    nap 1 if e.message.include?("same priorities") || e.message.include?("not ready")
    pop_gcp_failed(e.message, e.class.name)
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  label def wait_deny_rules
    client = credential.lockout_global_operations_client
    ops = deny_rule_ops.map { client.get(project: gcp_project_id, operation: it) }
    nap 1 unless ops.all? { it.status == :DONE }

    if (failed = ops.find { op_error?(it) })
      Clog.emit("GCP fence rule failed, retrying", {gcp_fence_rule_retry: {server_ubid: postgres_server.ubid, error: op_error_message(failed)}})
      hop_add_deny_rules
    end
    hop_reset_vm
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  label def reset_vm
    op = credential.lockout_compute_client.reset(project: gcp_project_id, zone: gcp_zone, instance: vm.name, request_id: strand.id)
    save_gcp_op("reset_vm", op_name: op.name, scope: "zone", scope_value: gcp_zone)
    hop_wait_reset_vm
  rescue Google::Cloud::NotFoundError
    pop_succeeded
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  label def wait_reset_vm
    op = poll_gcp_op("reset_vm", client: credential.lockout_zone_operations_client)
    nap 1 unless op.status == :DONE
    pop_gcp_failed(op_error_message(op)) if op_error?(op)
    pop_succeeded
  rescue *GCP_ERRORS => e
    pop_gcp_failed(e.message, e.class.name)
  end

  def lockout_with_pg_stop
    postgres_server.vm.sshable.cmd(
      "timeout 10 sudo pg_ctlcluster :version main stop -m immediate",
      version: postgres_server.version,
      timeout: 15,
    )
  end

  def lockout_with_hba
    postgres_server.vm.sshable.cmd(
      "timeout 10 sudo postgres/bin/lockout-hba :version",
      version: postgres_server.version,
      timeout: 15,
    )
  end

  def lockout_with_host_routing
    postgres_server.vm.vm_host.sshable.cmd(
      "timeout 10 sudo ip link set :interface down", interface: "vetho#{postgres_server.vm.inhost_name}",
      timeout: 15,
    )
  end

  def lockout_with_detach_nic
    client = postgres_server.vm.location.location_credential_aws.client
    network_interface = client.describe_network_interfaces(
      network_interface_ids: [postgres_server.vm.user_nic.nic_aws_resource.network_interface_id],
    ).network_interfaces.first
    client.detach_network_interface(
      attachment_id: network_interface.attachment.attachment_id,
      force: true,
    )
  end

  private

  def pop_succeeded
    Clog.emit("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: postgres_server.ubid, mechanism:}})
    pop "lockout_succeeded"
  end

  def pop_gcp_failed(error, error_class = nil)
    Clog.emit("GCP lockout failed", {gcp_lockout_failed: {server_ubid: postgres_server.ubid, mechanism:, error:, error_class:}})
    pop "lockout_failed"
  end

  def deny_rules
    v1 = Google::Cloud::Compute::V1
    destinations = {"ipv4" => ["0.0.0.0/0", "#{vm.user_nic.private_ipv4_address}/32"]}
    destinations["ipv6"] = ["::/0", vm.ephemeral_net6.to_s] if vm.ephemeral_net6
    ports = PostgresResource::PG_FIREWALL_RULE_PORT_RANGES.map { it.begin.to_s }

    destinations.map do |ip_version, (source, destination)|
      v1::FirewallPolicyRule.new(
        rule_name: "#{GcpFirewallPolicy.fence_rule_prefix(vm)}#{ip_version}",
        description: "Ubicloud lockout of #{postgres_server.ubid}",
        direction: "INGRESS",
        action: "deny",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: [source],
          dest_ip_ranges: [destination],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports:)],
        ),
      )
    end
  end

  def vm
    @vm ||= postgres_server.vm
  end

  def credential
    @credential ||= vm.location.location_credential_gcp
  end

  def gcp_project_id
    credential.project_id
  end

  def gcp_zone
    @gcp_zone ||= "#{vm.location.name.delete_prefix("gcp-")}-#{vm.vm_gcp_resource.location_az.az}"
  end

  def firewall_policy
    vm.user_nic.nic_gcp_resource.vpc_name
  end
end
