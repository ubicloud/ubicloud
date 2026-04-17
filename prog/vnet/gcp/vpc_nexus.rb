# frozen_string_literal: true

class Prog::Vnet::Gcp::VpcNexus < Prog::Base
  include GcpLro
  include GcpFirewallPolicy

  subject_is :gcp_vpc

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze
  DENY_RULE_BASE_PRIORITY = 65534
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
  rescue Sequel::UniqueConstraintViolation, Sequel::ValidationFailed
    GcpVpc.where(project_id:, location_id:).first!.strand
  end

  label def start
    register_deadline("wait", 5 * 60)
    hop_create_vpc
  end

  label def create_vpc
    begin
      network = credential.networks_client.get(
        project: gcp_project_id,
        network: gcp_vpc.name,
      )
      cache_network_self_link(network)
    rescue Google::Cloud::NotFoundError
      begin
        op = credential.networks_client.insert(
          project: gcp_project_id,
          network_resource: Google::Cloud::Compute::V1::Network.new(
            name: gcp_vpc.name,
            description: "Ubicloud VPC network for #{gcp_vpc.name}#{GcpE2eLabels.description_suffix}",
            auto_create_subnetworks: false,
            routing_config: Google::Cloud::Compute::V1::NetworkRoutingConfig.new(
              routing_mode: "REGIONAL",
            ),
          ),
        )
        save_gcp_op(op.name, "global", name: "create_vpc")
        hop_wait_create_vpc
      rescue Google::Cloud::AlreadyExistsError
        # Another strand created the VPC between our GET and INSERT
        network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
        cache_network_self_link(network)
      end
    end

    hop_create_firewall_policy
  end

  label def wait_create_vpc
    poll_and_clear_gcp_op(name: "create_vpc") do |op|
      credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "VPC #{gcp_vpc.name}", error: op_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP VPC creation LRO failed, clearing op and retrying",
        {gcp_vpc_retry: {vpc: gcp_vpc.name, error: op_error_message(op)}})
      clear_gcp_op(name: "create_vpc")
      hop_create_vpc
    end

    network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
    cache_network_self_link(network)

    hop_create_firewall_policy
  end

  label def create_firewall_policy
    policy = begin
      op = credential.network_firewall_policies_client.insert(
        project: gcp_project_id,
        firewall_policy_resource: Google::Cloud::Compute::V1::FirewallPolicy.new(
          name: firewall_policy_name,
          description: "Ubicloud network firewall policy for #{gcp_vpc.name}#{GcpE2eLabels.description_suffix}",
        ),
      )
      save_gcp_op(op.name, "global", name: "create_fw_policy")
      hop_wait_firewall_policy_created
    rescue Google::Cloud::AlreadyExistsError
      # Policy already exists: either a concurrent strand just created
      # it, or we are on the second pass after wait_firewall_policy_created
      # hopped back here. Fetch it so we can continue with association.
      credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
    end

    vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
    if policy.associations.any? { |a| a.attachment_target == vpc_target }
      hop_create_vpc_deny_rules
    end

    begin
      assoc_op = credential.network_firewall_policies_client.add_association(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_association_resource: Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
          name: gcp_vpc.name,
          attachment_target: vpc_target,
        ),
      )
      save_gcp_op(assoc_op.name, "global", name: "associate_fw_policy")
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
  end

  label def wait_firewall_policy_created
    poll_and_clear_gcp_op(name: "create_fw_policy") do |op|
      credential.network_firewall_policies_client.get(project: gcp_project_id, firewall_policy: firewall_policy_name)
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "firewall policy #{firewall_policy_name}", error: op_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      raise "GCP firewall policy #{firewall_policy_name} creation failed: #{op_error_message(op)}"
    end

    gcp_vpc.update(firewall_policy_name:)
    hop_create_firewall_policy
  end

  label def wait_firewall_policy_associated
    poll_and_clear_gcp_op(name: "associate_fw_policy") do |op|
      vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
      if policy.associations.any? { |a| a.attachment_target == vpc_target }
        Clog.emit("GCP LRO error but firewall policy association exists",
          {gcp_lro_recovered: {resource: "firewall policy association #{firewall_policy_name}", error: op_error_message(op)}})
      else
        Clog.emit("GCP firewall policy association LRO failed, clearing op and retrying",
          {gcp_assoc_retry: {policy: firewall_policy_name, vpc: gcp_vpc.name, error: op_error_message(op)}})
        clear_gcp_op(name: "associate_fw_policy")
        hop_create_firewall_policy
      end
    end
    hop_create_vpc_deny_rules
  end

  label def create_vpc_deny_rules
    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY,
      direction: "INGRESS",
      action: "deny",
      src_ip_ranges: RFC1918_RANGES,
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 1,
      direction: "EGRESS",
      action: "deny",
      dest_ip_ranges: RFC1918_RANGES,
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 2,
      direction: "INGRESS",
      action: "deny",
      src_ip_ranges: GCE_INTERNAL_IPV6_RANGES,
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 3,
      direction: "EGRESS",
      action: "deny",
      dest_ip_ranges: GCE_INTERNAL_IPV6_RANGES,
    )

    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    nap 60 * 60 * 24 * 365
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
      resp = credential.crm_client.list_tag_keys(parent: "projects/#{gcp_project_id}")
      (resp.tag_keys || []).select do |tk|
        tk.short_name.start_with?("ubicloud-fw-") &&
          tk.purpose == "GCE_FIREWALL" &&
          tk.purpose_data&.dig("network") == network_self_link
      end.map(&:name)
    else
      []
    end

    policy_exists = true
    pending_assoc_names = begin
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
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

    save_gcp_op(op.name, "global", name: "remove_assoc")
    update_stack({
      "pending_assoc_names" => new_pending,
      "remove_assoc_resource_name" => assoc_name,
    })
    hop_wait_policy_association_removed
  end

  label def wait_policy_association_removed
    assoc_name = frame["remove_assoc_resource_name"]
    poll_and_clear_gcp_op(name: "remove_assoc") do |err_op|
      begin
        policy = credential.network_firewall_policies_client.get(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
        )
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

    save_gcp_op(op.name, "global", name: "delete_fw_policy")
    hop_wait_firewall_policy_deleted
  end

  label def wait_firewall_policy_deleted
    drift = false
    poll_and_clear_gcp_op(name: "delete_fw_policy") do |err_op|
      begin
        policy = credential.network_firewall_policies_client.get(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
        )
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
    resp = credential.crm_client.list_tag_values(parent: tk_name)
    tv_names = resp.tag_values&.map(&:name) || []
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
      "delete_tv_op_name" => op.name,
      "delete_tv_name" => tv_name,
    })
    hop_wait_firewall_tag_value_deleted
  end

  label def wait_firewall_tag_value_deleted
    op_name = frame["delete_tv_op_name"]
    tv_name = frame["delete_tv_name"]
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

    update_stack({"delete_tv_op_name" => nil, "delete_tv_name" => nil})
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
      "delete_tk_op_name" => op.name,
      "delete_tk_name" => tk_name,
    })
    hop_wait_firewall_tag_key_deleted
  end

  label def wait_firewall_tag_key_deleted
    op_name = frame["delete_tk_op_name"]
    tk_name = frame["delete_tk_name"]
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
          "delete_tk_op_name" => nil,
          "delete_tk_name" => nil,
        })
        hop_delete_firewall_tag_values_start
      end

      if op.error.code == 9
        Clog.emit("GCP tag key has new children after LRO; re-draining values",
          {gcp_tag_key_drift: {tag_key: tk_name, lro_error: op.error.message}})
        update_stack({"delete_tk_op_name" => nil, "delete_tk_name" => nil})
        hop_delete_firewall_tag_values_start
      end

      raise "GCP tag key #{tk_name} deletion LRO failed (tag key still present): #{op.error.message}"
    end

    update_stack({
      "pending_tag_key_names" => frame["pending_tag_key_names"].drop(1),
      "delete_tk_op_name" => nil,
      "delete_tk_name" => nil,
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

    save_gcp_op(op.name, "global", name: "delete_vpc")
    hop_wait_vpc_network_deleted
  end

  label def wait_vpc_network_deleted
    poll_and_clear_gcp_op(name: "delete_vpc") do |err_op|
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

  def firewall_policy_name
    gcp_vpc.name
  end

  def verify_firewall_policy_associated_with_vpc!(vpc_target)
    policy = credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
    )
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
