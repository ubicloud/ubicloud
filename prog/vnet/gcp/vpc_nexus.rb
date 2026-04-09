# frozen_string_literal: true

class Prog::Vnet::Gcp::VpcNexus < Prog::Base
  include GcpLro

  subject_is :gcp_vpc

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze
  DENY_RULE_BASE_PRIORITY = 65534

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
      vpc
    end
  rescue Sequel::UniqueConstraintViolation, Sequel::ValidationFailed
    GcpVpc.where(project_id:, location_id:).first!
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
            auto_create_subnetworks: false,
            routing_config: Google::Cloud::Compute::V1::NetworkRoutingConfig.new(
              routing_mode: "REGIONAL",
            ),
          ),
        )
        save_gcp_op(op.name, "global")
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
    poll_and_clear_gcp_op do |op|
      credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "VPC #{gcp_vpc.name}", error: op_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      Clog.emit("GCP VPC creation LRO failed, clearing op and retrying",
        {gcp_vpc_retry: {vpc: gcp_vpc.name, error: op_error_message(op)}})
      clear_gcp_op
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
          description: "Ubicloud network firewall policy for #{gcp_vpc.name}",
        ),
      )
      save_gcp_op(op.name, "global")
      hop_wait_firewall_policy_created
    rescue Google::Cloud::AlreadyExistsError
      # Policy already exists -- either a concurrent strand just created
      # it, or we are on the second pass after wait_firewall_policy_created
      # hopped back here. Fetch it so we can continue with association.
      credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
    end

    vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
    if policy.associations&.any? { |a| a.attachment_target == vpc_target }
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
      save_gcp_op(assoc_op.name, "global")
      hop_wait_firewall_policy_associated
    rescue Google::Cloud::AlreadyExistsError, Google::Cloud::InvalidArgumentError => e
      if e.is_a?(Google::Cloud::AlreadyExistsError) || e.message.include?("already exists")
        hop_create_vpc_deny_rules
      elsif e.message.include?("is not ready")
        Clog.emit("GCP resource not ready for association, will retry",
          {gcp_resource_not_ready: Util.exception_to_hash(e, into: {policy: firewall_policy_name, vpc: gcp_vpc.name})})
        nap 5
      else
        raise
      end
    end
  end

  label def wait_firewall_policy_created
    poll_and_clear_gcp_op do |op|
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
    poll_and_clear_gcp_op do |op|
      vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc.name}"
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
      if policy.associations&.any? { |a| a.attachment_target == vpc_target }
        Clog.emit("GCP LRO error but firewall policy association exists",
          {gcp_lro_recovered: {resource: "firewall policy association #{firewall_policy_name}", error: op_error_message(op)}})
      else
        Clog.emit("GCP firewall policy association LRO failed, clearing op and retrying",
          {gcp_assoc_retry: {policy: firewall_policy_name, vpc: gcp_vpc.name, error: op_error_message(op)}})
        clear_gcp_op
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

    delete_all_firewall_tag_keys
    delete_firewall_policy
    delete_vpc_network

    gcp_vpc.destroy
    pop "vpc destroyed"
  end

  private

  def firewall_policy_name
    gcp_vpc.name
  end

  def ensure_policy_rule(priority:, direction:, action:, src_ip_ranges: nil, dest_ip_ranges: nil, layer4_configs: nil, target_secure_tags: nil)
    matcher_attrs = {}
    matcher_attrs[:src_ip_ranges] = src_ip_ranges if src_ip_ranges
    matcher_attrs[:dest_ip_ranges] = dest_ip_ranges if dest_ip_ranges

    matcher_attrs[:layer4_configs] = if layer4_configs
      layer4_configs.map { |cfg|
        Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(**cfg)
      }
    else
      [
        Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all"),
      ]
    end

    rule_attrs = {
      priority:,
      direction:,
      action:,
      match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(**matcher_attrs),
    }

    if target_secure_tags
      rule_attrs[:target_secure_tags] = target_secure_tags.map { |t|
        Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: t)
      }
    end

    rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(**rule_attrs)

    existing = begin
      credential.network_firewall_policies_client.get_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:,
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      nil
    end

    if existing
      unless policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs: matcher_attrs[:layer4_configs], target_secure_tags:)
        Clog.emit("GCP firewall priority collision, overwriting rule",
          {gcp_priority_collision: {priority:, direction:, action:}})
        credential.network_firewall_policies_client.patch_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          priority:,
          firewall_policy_rule_resource: rule,
        )
      end
    else
      begin
        credential.network_firewall_policies_client.add_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          firewall_policy_rule_resource: rule,
        )
      rescue ::Google::Cloud::AlreadyExistsError
        # Concurrent strand added this rule -- proceed.
      end
    end
  end

  def policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs:, target_secure_tags: nil)
    match = existing.match
    existing.direction == direction &&
      existing.action == action &&
      sorted_ranges_eq?(match&.src_ip_ranges, src_ip_ranges) &&
      sorted_ranges_eq?(match&.dest_ip_ranges, dest_ip_ranges) &&
      normalize_layer4_configs(match&.layer4_configs&.to_a || []) == normalize_layer4_configs(layer4_configs || []) &&
      existing.target_secure_tags.map(&:name).sort == (target_secure_tags || []).sort
  end

  def sorted_ranges_eq?(existing_ranges, desired_ranges)
    (existing_ranges&.to_a || []).sort == (desired_ranges || []).sort
  end

  def normalize_layer4_configs(configs)
    configs.map { |c| [c.ip_protocol, (c.ports&.to_a || []).sort] }.sort
  end

  def delete_all_firewall_tag_keys
    network_self_link = gcp_vpc.network_self_link
    return unless network_self_link

    resp = credential.crm_client.list_tag_keys(parent: "projects/#{gcp_project_id}")
    (resp.tag_keys || []).each do |tk|
      next unless tk.short_name.start_with?("ubicloud-fw-") && tk.purpose == "GCE_FIREWALL"
      next unless tk.purpose_data&.dig("network") == network_self_link

      values_resp = credential.crm_client.list_tag_values(parent: tk.name)
      (values_resp.tag_values || []).each { |tv| credential.crm_client.delete_tag_value(tv.name) }

      credential.crm_client.delete_tag_key(tk.name)
    rescue Google::Cloud::Error, Google::Apis::ClientError, RuntimeError => e
      Clog.emit("Failed to delete firewall tag key during VPC cleanup",
        {vpc_cleanup_tag_error: Util.exception_to_hash(e, into: {tag_key: tk.name})})
    end
  rescue Google::Cloud::Error, Google::Apis::ClientError, RuntimeError => e
    Clog.emit("Failed to list tag keys during VPC cleanup",
      {vpc_cleanup_list_tags_error: Util.exception_to_hash(e)})
  end

  def delete_firewall_policy
    begin
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
      policy.associations.each do |assoc|
        credential.network_firewall_policies_client.remove_association(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          name: assoc.name,
        )
      end

      credential.network_firewall_policies_client.delete(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
    rescue Google::Cloud::NotFoundError
      # Already deleted
    end
  rescue Google::Cloud::Error => e
    Clog.emit("Failed to delete firewall policy during VPC cleanup",
      {vpc_cleanup_policy_error: Util.exception_to_hash(e, into: {policy: firewall_policy_name})})
  end

  def delete_vpc_network
    credential.networks_client.delete(
      project: gcp_project_id,
      network: gcp_vpc.name,
    )
  rescue Google::Cloud::NotFoundError
    # Already deleted
  rescue Google::Cloud::InvalidArgumentError => e
    raise if e.message.include?("being used by")
    Clog.emit("Failed to delete VPC network during cleanup",
      {vpc_cleanup_network_error: Util.exception_to_hash(e, into: {vpc: gcp_vpc.name})})
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
