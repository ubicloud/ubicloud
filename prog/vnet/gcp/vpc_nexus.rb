# frozen_string_literal: true

class Prog::Vnet::Gcp::VpcNexus < Prog::Base
  include GcpLro
  include GcpFirewallPolicy

  subject_is :gcp_vpc

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze
  DENY_RULE_BASE_PRIORITY = 65534
  DENY_RULE_DIRECTIONS = {"INGRESS" => :src_ip_ranges, "EGRESS" => :dest_ip_ranges}.freeze
  VERIFY_ASSOC_MAX_TRIES = 5

  def self.assemble(project_id, location_id)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      vpc = GcpVpc.create(
        project_id: project.id,
        location_id: location.id,
        name: "ubicloud-#{project.ubid}-#{location.ubid}",
      )
      Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "start")
    end
  end

  label def start
    register_deadline("wait", 5 * 60)
    hop_create_vpc
  end

  label def create_vpc
    op = credential.networks_client.insert(
      project: gcp_project_id,
      network_resource: Google::Cloud::Compute::V1::Network.new(
        name: gcp_vpc.name,
        description: "Ubicloud VPC network for #{gcp_vpc.name} [Ubicloud=#{Config.provider_resource_tag_value}]",
        auto_create_subnetworks: false,
        routing_config: Google::Cloud::Compute::V1::NetworkRoutingConfig.new(
          routing_mode: "REGIONAL",
        ),
      ),
    )
    save_gcp_op("create_vpc", op_name: op.name, scope: "global")
    hop_wait_create_vpc
  rescue Google::Cloud::AlreadyExistsError
    # Another strand already created the VPC; cache the self_link and skip
    # the wait.
    network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
    cache_network_self_link(network)
    hop_create_firewall_policy
  end

  label def wait_create_vpc
    poll_and_clear_gcp_op("create_vpc") do |op|
      credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "VPC #{gcp_vpc.name}", error: op_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP VPC creation LRO failed, clearing op and retrying",
        {gcp_vpc_retry: {vpc: gcp_vpc.name, error: op_error_message(op)}})
      clear_gcp_op("create_vpc")
      hop_create_vpc
    end

    network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
    cache_network_self_link(network)

    hop_create_firewall_policy
  end

  label def create_firewall_policy
    op = credential.network_firewall_policies_client.insert(
      project: gcp_project_id,
      firewall_policy_resource: Google::Cloud::Compute::V1::FirewallPolicy.new(
        name: firewall_policy_name,
        description: "Ubicloud network firewall policy for #{gcp_vpc.name} [Ubicloud=#{Config.provider_resource_tag_value}]",
      ),
    )
    save_gcp_op("create_fw_policy", op_name: op.name, scope: "global")
    hop_wait_firewall_policy_created
  rescue Google::Cloud::AlreadyExistsError
    # Concurrent strand or prior-run insert already landed. Skip ahead.
    hop_associate_firewall_policy
  end

  label def wait_firewall_policy_created
    poll_and_clear_gcp_op("create_fw_policy") do |op|
      get_firewall_policy
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "firewall policy #{firewall_policy_name}", error: op_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      raise "GCP firewall policy #{firewall_policy_name} creation failed: #{op_error_message(op)}"
    end

    hop_associate_firewall_policy
  end

  label def associate_firewall_policy
    vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
    policy = get_firewall_policy
    hop_create_vpc_deny_rules if policy.associations.any? { |a| a.attachment_target == vpc_target }

    assoc_op = credential.network_firewall_policies_client.add_association(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
      firewall_policy_association_resource: Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
        name: gcp_vpc.name,
        attachment_target: vpc_target,
      ),
    )
    save_gcp_op("associate_fw_policy", op_name: assoc_op.name, scope: "global")
    hop_wait_firewall_policy_associated
  rescue Google::Cloud::AlreadyExistsError
    verify_firewall_policy_associated_with_vpc!(vpc_target)
  rescue Google::Cloud::InvalidArgumentError => e
    case e.message
    when /already exists/
      verify_firewall_policy_associated_with_vpc!(vpc_target)
    when /is not ready/
      Clog.emit("GCP resource not ready for association, will retry",
        {gcp_resource_not_ready: Util.exception_to_hash(e, into: {policy: firewall_policy_name, vpc: gcp_vpc.name})})
      nap 5
    else
      raise
    end
  end

  label def wait_firewall_policy_associated
    poll_and_clear_gcp_op("associate_fw_policy") do |op|
      vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
      policy = get_firewall_policy
      if policy.associations.any? { |a| a.attachment_target == vpc_target }
        Clog.emit("GCP LRO error but firewall policy association exists",
          {gcp_lro_recovered: {resource: "firewall policy association #{firewall_policy_name}", error: op_error_message(op)}})
      else
        Clog.emit("GCP firewall policy association LRO failed, clearing op and retrying",
          {gcp_assoc_retry: {policy: firewall_policy_name, vpc: gcp_vpc.name, error: op_error_message(op)}})
        clear_gcp_op("associate_fw_policy")
        hop_create_firewall_policy
      end
    end
    hop_create_vpc_deny_rules
  end

  label def create_vpc_deny_rules
    # 2 address families x 2 directions = 4 rules. Priorities walk down
    # from DENY_RULE_BASE_PRIORITY in the order emitted (IPv4 ingress,
    # IPv4 egress, IPv6 ingress, IPv6 egress).
    priority = DENY_RULE_BASE_PRIORITY
    [RFC1918_RANGES, GCE_INTERNAL_IPV6_RANGES].each do |ranges|
      DENY_RULE_DIRECTIONS.each do |direction, ip_arg|
        ensure_firewall_policy_rule(priority:, direction:, action: "deny", layer4_configs: [{ip_protocol: "all"}], **{ip_arg => ranges})
        priority -= 1
      end
    end

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_update_firewall_rules_set? do
      hop_update_firewall_rules
    end

    nap 60 * 60 * 24 * 365
  end

  label def update_firewall_rules
    # Pop returns to wait; firewall-rule sync owns its own frame for
    # CRM LRO pending-op bookkeeping (pending_tag_key_crm_op, etc.).
    if retval&.dig("msg") == "firewall rules updated"
      hop_wait
    end

    decr_update_firewall_rules
    push Prog::Vnet::Gcp::VpcUpdateFirewallRules, {}, "update_firewall_rules"
  end

  label def destroy
    register_deadline("destroy", 5 * 60)
    decr_destroy

    unless gcp_vpc.private_subnets.empty?
      Clog.emit("Cannot destroy VPC with active subnets", gcp_vpc)
      nap 10
    end

    hop_enumerate_destroy_state
  end

  label def enumerate_destroy_state
    network_self_link = gcp_vpc.network_self_link
    pending_tag_key_names = if network_self_link
      credential.crm_client
        .fetch_all(items: :tag_keys) { |token, s| s.list_tag_keys(parent: "projects/#{gcp_project_id}", page_token: token) }
        .select { |tk|
          tk.short_name.start_with?("ubicloud-fw-") &&
            tk.purpose == "GCE_FIREWALL" &&
            tk.purpose_data&.dig("network") == network_self_link
        }.map(&:name)
    else
      [].freeze
    end

    policy_exists = true
    pending_assoc_names = begin
      policy = get_firewall_policy
      policy.associations.map(&:name)
    rescue Google::Cloud::NotFoundError
      policy_exists = false
      []
    end

    update_stack({
      "pending_tag_key_names" => pending_tag_key_names,
      "pending_tag_value_names" => [],
      "pending_assoc_names" => pending_assoc_names,
    })

    if pending_assoc_names.any?
      hop_remove_policy_associations
    elsif policy_exists
      hop_delete_firewall_policy_op
    else
      hop_delete_firewall_tag_values_start
    end
  end

  label def remove_policy_associations
    pending = frame["pending_assoc_names"]
    assoc_name = pending.first
    new_pending = pending.drop(1)

    begin
      op = credential.network_firewall_policies_client.remove_association(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        name: assoc_name,
      )
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP firewall policy association already gone; proceeding",
        {gcp_firewall_assoc_already_gone: {policy: firewall_policy_name, association: assoc_name}})
      update_stack({"pending_assoc_names" => new_pending})
      if new_pending.any?
        hop_remove_policy_associations
      else
        hop_delete_firewall_policy_op
      end
    end

    save_gcp_op("remove_assoc", op_name: op.name, scope: "global")
    update_stack({
      "pending_assoc_names" => new_pending,
      "remove_assoc_resource_name" => assoc_name,
    })
    hop_wait_policy_association_removed
  end

  label def wait_policy_association_removed
    assoc_name = frame["remove_assoc_resource_name"]
    poll_and_clear_gcp_op("remove_assoc") do |err_op|
      begin
        policy = get_firewall_policy
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP firewall policy already gone despite LRO error; proceeding",
          {gcp_firewall_policy_already_gone: {policy: firewall_policy_name, lro_error: op_error_message(err_op)}})
        next
      end
      if policy.associations.any? { |a| a.name == assoc_name }
        raise "GCE firewall policy association #{assoc_name} removal LRO failed (association still present): #{op_error_message(err_op)}"
      end
      Clog.emit("GCP firewall policy association already gone despite LRO error; proceeding",
        {gcp_firewall_assoc_already_gone: {policy: firewall_policy_name, association: assoc_name, lro_error: op_error_message(err_op)}})
    end

    update_stack({"remove_assoc_resource_name" => nil})
    if frame["pending_assoc_names"].any?
      hop_remove_policy_associations
    else
      hop_delete_firewall_policy_op
    end
  end

  label def delete_firewall_policy_op
    begin
      op = credential.network_firewall_policies_client.delete(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP firewall policy already gone; proceeding",
        {gcp_firewall_policy_already_gone: {policy: firewall_policy_name}})
      hop_delete_firewall_tag_values_start
    end

    save_gcp_op("delete_fw_policy", op_name: op.name, scope: "global")
    hop_wait_firewall_policy_deleted
  end

  label def wait_firewall_policy_deleted
    drift = false
    poll_and_clear_gcp_op("delete_fw_policy") do |err_op|
      begin
        policy = get_firewall_policy
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP firewall policy already gone despite LRO error; proceeding",
          {gcp_firewall_policy_already_gone: {policy: firewall_policy_name, lro_error: op_error_message(err_op)}})
        next
      end

      if policy.associations.any?
        Clog.emit("GCP firewall policy still has associations after LRO; re-enumerating",
          {gcp_firewall_policy_drift: {policy: firewall_policy_name, associations: policy.associations.map(&:name), lro_error: op_error_message(err_op)}})
        drift = true
        next
      end

      raise "GCE firewall policy #{firewall_policy_name} deletion LRO failed (policy still present, no pending associations): #{op_error_message(err_op)}"
    end

    if drift
      hop_enumerate_destroy_state
    else
      hop_delete_firewall_tag_values_start
    end
  end

  label def delete_firewall_tag_values_start
    pending_tk = frame["pending_tag_key_names"]
    if pending_tk.empty?
      hop_delete_vpc_network_op
    end

    tk_name = pending_tk.first
    tv_names = credential.crm_client
      .fetch_all(items: :tag_values) { |token, s| s.list_tag_values(parent: tk_name, page_token: token) }
      .map(&:name)
    update_stack({"pending_tag_value_names" => tv_names})
    hop_delete_firewall_tag_values
  end

  label def delete_firewall_tag_values
    pending_tv = frame["pending_tag_value_names"]
    if pending_tv.empty?
      hop_delete_firewall_tag_key_current
    end

    tv_name = pending_tv.first
    new_pending = pending_tv.drop(1)

    begin
      op = credential.crm_client.delete_tag_value(tv_name)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404
      Clog.emit("GCP tag value already gone; proceeding",
        {gcp_tag_value_already_gone: {tag_value: tv_name}})
      update_stack({"pending_tag_value_names" => new_pending})
      hop_delete_firewall_tag_values
    end

    update_stack({
      "pending_tag_value_names" => new_pending,
      "delete_tv" => {"op_name" => op.name, "name" => tv_name},
    })
    hop_wait_firewall_tag_value_deleted
  end

  label def wait_firewall_tag_value_deleted
    op_name = frame["delete_tv"]["op_name"]
    tv_name = frame["delete_tv"]["name"]
    op = credential.crm_client.get_operation(op_name)
    nap 5 unless op.done?

    if op.error
      begin
        credential.crm_client.get_tag_value(tv_name)
        raise "GCP tag value #{tv_name} deletion LRO failed (tag value still present): #{op.error.message}"
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 404
        Clog.emit("GCP tag value already gone despite LRO error; proceeding",
          {gcp_tag_value_already_gone: {tag_value: tv_name, lro_error: op.error.message}})
      end
    end

    update_stack({"delete_tv" => nil})
    hop_delete_firewall_tag_values
  end

  label def delete_firewall_tag_key_current
    pending_tk = frame["pending_tag_key_names"]
    tk_name = pending_tk.first

    begin
      op = credential.crm_client.delete_tag_key(tk_name)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404
      Clog.emit("GCP tag key already gone; proceeding",
        {gcp_tag_key_already_gone: {tag_key: tk_name}})
      update_stack({"pending_tag_key_names" => pending_tk.drop(1)})
      hop_delete_firewall_tag_values_start
    end

    update_stack({
      "delete_tk" => {"op_name" => op.name, "name" => tk_name},
    })
    hop_wait_firewall_tag_key_deleted
  end

  label def wait_firewall_tag_key_deleted
    op_name = frame["delete_tk"]["op_name"]
    tk_name = frame["delete_tk"]["name"]
    op = credential.crm_client.get_operation(op_name)
    nap 5 unless op.done?

    if op.error
      begin
        credential.crm_client.get_tag_key(tk_name)
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 404
        Clog.emit("GCP tag key already gone despite LRO error; proceeding",
          {gcp_tag_key_already_gone: {tag_key: tk_name, lro_error: op.error.message}})
        update_stack({
          "pending_tag_key_names" => frame["pending_tag_key_names"].drop(1),
          "delete_tk" => nil,
        })
        hop_delete_firewall_tag_values_start
      end

      if op.error.code == 9
        Clog.emit("GCP tag key has new children after LRO; re-draining values",
          {gcp_tag_key_drift: {tag_key: tk_name, lro_error: op.error.message}})
        update_stack({"delete_tk" => nil})
        hop_delete_firewall_tag_values_start
      end

      raise "GCP tag key #{tk_name} deletion LRO failed (tag key still present): #{op.error.message}"
    end

    update_stack({
      "pending_tag_key_names" => frame["pending_tag_key_names"].drop(1),
      "delete_tk" => nil,
    })
    hop_delete_firewall_tag_values_start
  end

  label def delete_vpc_network_op
    begin
      op = credential.networks_client.delete(
        project: gcp_project_id,
        network: gcp_vpc.name,
      )
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP VPC network already gone; proceeding",
        {gcp_vpc_already_gone: {network: gcp_vpc.name}})
      hop_finalize_destroy
    end

    save_gcp_op("delete_vpc", op_name: op.name, scope: "global")
    hop_wait_vpc_network_deleted
  end

  label def wait_vpc_network_deleted
    poll_and_clear_gcp_op("delete_vpc") do |err_op|
      begin
        credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP VPC network already gone despite LRO error; proceeding",
          {gcp_vpc_already_gone: {network: gcp_vpc.name, lro_error: op_error_message(err_op)}})
        next
      end
      raise "GCE VPC network #{gcp_vpc.name} deletion LRO failed (network still present): #{op_error_message(err_op)}"
    end

    hop_finalize_destroy
  end

  label def finalize_destroy
    gcp_vpc.destroy
    pop "vpc destroyed"
  end

  private

  def get_firewall_policy
    credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
    )
  end

  def firewall_policy_name
    gcp_vpc.name
  end

  def verify_firewall_policy_associated_with_vpc!(vpc_target)
    policy = get_firewall_policy
    if policy.associations.any? { |a| a.attachment_target == vpc_target }
      update_stack({"verify_assoc_try" => 0})
      hop_create_vpc_deny_rules
    end

    current_associations = policy.associations.map { |a| {name: a.name, attachment_target: a.attachment_target} }
    try = (frame["verify_assoc_try"] || 0) + 1
    if try >= VERIFY_ASSOC_MAX_TRIES
      raise "GCP firewall policy #{firewall_policy_name} association with VPC #{gcp_vpc.name} (#{vpc_target}) not present after #{try} attempts; current associations: #{current_associations.inspect}"
    end

    Clog.emit("GCP firewall policy association missing after already-exists rescue", {
      gcp_assoc_missing: {
        policy: firewall_policy_name,
        vpc: gcp_vpc.name,
        vpc_target:,
        try:,
        current_associations:,
      },
    })
    update_stack({"verify_assoc_try" => try})
    nap 5
  end

  def cache_network_self_link(network)
    return if gcp_vpc.network_self_link
    gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/#{gcp_project_id}/global/networks/#{network.id}")
  end

  def credential
    @credential ||= gcp_vpc.location.location_credential_gcp
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end
end
