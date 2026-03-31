# frozen_string_literal: true

require "google/cloud/compute/v1"
require "google/apis/cloudresourcemanager_v3"
require_relative "../../../lib/gcp_lro"

class Prog::Vnet::Gcp::SubnetNexus < Prog::Base
  include GcpLro

  subject_is :private_subnet

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  # GCE internal IPv6 ranges used by dual-stack subnets (ULA space)
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze

  # GCP Network Firewall Policy priority layout (one policy per VPC, flat 0–65535 space).
  # Lower number = higher precedence. Three bands:
  #
  #   1000–8998  Subnet ALLOW EGRESS: each subnet gets a pair (P for IPv4, P+1 for IPv6).
  #              Targeted via subnet secure tags so only member VMs are affected.
  #   10000+     Per-VM INGRESS: tag-targeted rules managed by UpdateFirewallRules.
  #              Each Ubicloud Firewall gets its own tag key; VMs bind to "active" tag values.
  #   65531–65534 VPC-wide DENY: unconditional deny for all private traffic (default-deny posture).
  #              Subnet/VM rules override these by having lower (= higher-precedence) priorities.
  #
  # See model/gcp/gcp_firewall_architecture.md for the full design.
  DENY_RULE_BASE_PRIORITY = 65534
  ALLOW_SUBNET_BASE_PRIORITY = 1000

  def self.vpc_name(project, location)
    "ubicloud-#{project.ubid}-#{location.ubid}"
  end

  label def start
    register_deadline("wait", 5 * 60)
    hop_create_vpc
  end

  label def create_vpc
    begin
      credential.networks_client.get(
        project: gcp_project_id,
        network: gcp_vpc_name
      )
    rescue Google::Cloud::NotFoundError
      begin
        op = credential.networks_client.insert(
          project: gcp_project_id,
          network_resource: Google::Cloud::Compute::V1::Network.new(
            name: gcp_vpc_name,
            auto_create_subnetworks: false,
            routing_config: Google::Cloud::Compute::V1::NetworkRoutingConfig.new(
              routing_mode: "REGIONAL"
            )
          )
        )
        save_gcp_op(op.name, "global")
        hop_wait_create_vpc
      rescue Google::Cloud::AlreadyExistsError
        # Another strand created the VPC between our GET and INSERT
      end
    end

    hop_create_firewall_policy
  end

  label def wait_create_vpc
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    if op_error?(op)
      begin
        credential.networks_client.get(project: gcp_project_id, network: gcp_vpc_name)
        Clog.emit("GCP LRO error but resource exists",
          {gcp_lro_recovered: {resource: "VPC #{gcp_vpc_name}", error: op_error_message(op)}})
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP VPC creation LRO failed, clearing op and retrying",
          {gcp_vpc_retry: {vpc: gcp_vpc_name, error: op_error_message(op)}})
        clear_gcp_op
        hop_create_vpc
      end
    end

    clear_gcp_op
    hop_create_firewall_policy
  end

  label def create_firewall_policy
    policy = begin
      credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name
      )
    rescue Google::Cloud::NotFoundError
      begin
        op = credential.network_firewall_policies_client.insert(
          project: gcp_project_id,
          firewall_policy_resource: Google::Cloud::Compute::V1::FirewallPolicy.new(
            name: firewall_policy_name,
            description: "Ubicloud network firewall policy for #{gcp_vpc_name}"
          )
        )
        save_gcp_op(op.name, "global")
        hop_wait_firewall_policy_created
      rescue Google::Cloud::AlreadyExistsError
        # Policy created by a concurrent strand between our GET and INSERT.
      end
      nil
    end

    # Re-fetch when we just created the policy (or a concurrent strand did)
    # so we can check existing associations.
    policy ||= credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name
    )

    # Ensure the policy is associated with the VPC network
    vpc_target = "projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}"
    if policy.associations&.any? { |a| a.attachment_target == vpc_target }
      hop_create_vpc_deny_rules
    end

    begin
      assoc_op = credential.network_firewall_policies_client.add_association(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_association_resource: Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
          name: gcp_vpc_name,
          attachment_target: vpc_target
        )
      )
      save_gcp_op(assoc_op.name, "global")
      hop_wait_firewall_policy_associated
    rescue Google::Cloud::AlreadyExistsError
      # Association created by a concurrent strand -- proceed.
      hop_create_vpc_deny_rules
    rescue Google::Cloud::InvalidArgumentError => e
      if e.message.include?("already exists")
        # GCP returns InvalidArgumentError (not AlreadyExistsError) when the
        # association name is already taken -- proceed.
        hop_create_vpc_deny_rules
      elsif e.message.include?("is not ready")
        # VPC network may not be fully propagated after creation LRO completes.
        Clog.emit("GCP resource not ready for association, will retry",
          {gcp_resource_not_ready: {policy: firewall_policy_name, vpc: gcp_vpc_name, error: e.message}})
        nap 5
      else
        raise
      end
    end
  end

  label def wait_firewall_policy_created
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    if op_error?(op)
      begin
        credential.network_firewall_policies_client.get(project: gcp_project_id, firewall_policy: firewall_policy_name)
        Clog.emit("GCP LRO error but resource exists",
          {gcp_lro_recovered: {resource: "firewall policy #{firewall_policy_name}", error: op_error_message(op)}})
      rescue Google::Cloud::NotFoundError
        raise "GCP firewall policy #{firewall_policy_name} creation failed: #{op_error_message(op)}"
      end
    end

    clear_gcp_op
    # Go back to create_firewall_policy which will re-fetch and ensure association
    hop_create_firewall_policy
  end

  label def wait_firewall_policy_associated
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    if op_error?(op)
      Clog.emit("GCP LRO error during firewall policy association",
        {gcp_lro_assoc_error: {policy: firewall_policy_name, error: op_error_message(op)}})
    end

    clear_gcp_op
    hop_create_vpc_deny_rules
  end

  label def create_vpc_deny_rules
    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY,
      direction: "INGRESS",
      action: "deny",
      src_ip_ranges: RFC1918_RANGES
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 1,
      direction: "EGRESS",
      action: "deny",
      dest_ip_ranges: RFC1918_RANGES
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 2,
      direction: "INGRESS",
      action: "deny",
      src_ip_ranges: GCE_INTERNAL_IPV6_RANGES
    )

    ensure_policy_rule(
      priority: DENY_RULE_BASE_PRIORITY - 3,
      direction: "EGRESS",
      action: "deny",
      dest_ip_ranges: GCE_INTERNAL_IPV6_RANGES
    )

    hop_create_subnet
  end

  label def create_subnet
    subnet_name = "ubicloud-#{private_subnet.ubid}"
    begin
      credential.subnetworks_client.get(
        project: gcp_project_id,
        region: gcp_region,
        subnetwork: subnet_name
      )
    rescue Google::Cloud::NotFoundError
      op = credential.subnetworks_client.insert(
        project: gcp_project_id,
        region: gcp_region,
        subnetwork_resource: Google::Cloud::Compute::V1::Subnetwork.new(
          name: subnet_name,
          ip_cidr_range: private_subnet.net4.to_s,
          network: "projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}",
          private_ip_google_access: true,
          stack_type: "IPV4_IPV6",
          ipv6_access_type: "EXTERNAL"
        )
      )
      save_gcp_op(op.name, "region", gcp_region)
      hop_wait_create_subnet
    end

    hop_create_tag_resources
  end

  label def wait_create_subnet
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    subnet_name = "ubicloud-#{private_subnet.ubid}"
    if op_error?(op)
      begin
        credential.subnetworks_client.get(project: gcp_project_id, region: gcp_region, subnetwork: subnet_name)
        Clog.emit("GCP LRO error but resource exists",
          {gcp_lro_recovered: {resource: "subnet #{subnet_name}", error: op_error_message(op)}})
      rescue Google::Cloud::NotFoundError
        raise "GCP subnet #{subnet_name} creation failed: #{op_error_message(op)}"
      end
    end

    clear_gcp_op
    hop_create_tag_resources
  end

  label def create_tag_resources
    tag_key_name = frame["tag_key_name"] || ensure_tag_key
    update_stack({"tag_key_name" => tag_key_name}) unless frame["tag_key_name"]

    subnet_tag_value_name = ensure_tag_value(tag_key_name, subnet_tag_short_name)
    update_stack({"subnet_tag_value_name" => subnet_tag_value_name})
    hop_create_subnet_allow_rules
  end

  label def create_subnet_allow_rules
    allocate_subnet_firewall_priority unless private_subnet.firewall_priority

    subnet_tag_value_name = frame["subnet_tag_value_name"]

    # Allow same-subnet IPv4 egress (overrides the VPC-wide deny-egress)
    ensure_policy_rule(
      priority: subnet_allow_priority,
      direction: "EGRESS",
      action: "allow",
      dest_ip_ranges: [private_subnet.net4.to_s],
      layer4_configs: [{ip_protocol: "all"}],
      target_secure_tags: [subnet_tag_value_name]
    )

    # Allow same-subnet IPv6 egress (overrides VPC-wide deny-egress-ipv6)
    ensure_policy_rule(
      priority: subnet_allow_priority + 1,
      direction: "EGRESS",
      action: "allow",
      dest_ip_ranges: [private_subnet.net6.to_s],
      layer4_configs: [{ip_protocol: "all"}],
      target_secure_tags: [subnet_tag_value_name]
    )

    hop_wait
  end

  label def wait
    when_refresh_keys_set? do
      # GCP has no IPsec tunnels -- nothing to rekey, just clear the semaphore
      decr_refresh_keys
    end

    when_update_firewall_rules_set? do
      private_subnet.vms.each(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end

    nap 10 * 60
  end

  label def destroy
    register_deadline("destroy", 5 * 60)
    decr_destroy
    private_subnet.remove_all_firewalls

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      delete_subnet_policy_rules
      delete_subnet_tag_resources

      begin
        subnet_name = "ubicloud-#{private_subnet.ubid}"
        op = credential.subnetworks_client.delete(
          project: gcp_project_id,
          region: gcp_region,
          subnetwork: subnet_name
        )
        save_gcp_op(op.name, "region", gcp_region)
        hop_wait_delete_subnet
      rescue Google::Cloud::NotFoundError
        # Already deleted
      rescue Google::Cloud::InvalidArgumentError => e
        raise unless e.message.include?("being used by")
        Clog.emit("GCP subnet still in use, retrying", {gcp_subnet_in_use: {subnet: subnet_name, error: e.message}})
        nap 5
      end

      hop_finish_destroy
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap rand(5..10)
    end
  end

  label def wait_delete_subnet
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    if op_error?(op)
      Clog.emit("GCP subnet deletion LRO error, proceeding with cleanup",
        {gcp_subnet_delete_error: {error: op_error_message(op)}})
    end

    clear_gcp_op
    hop_finish_destroy
  end

  label def finish_destroy
    last_subnet = private_subnet.project.private_subnets.all? { |ps|
      ps.id == private_subnet.id || ps.location_id != private_subnet.location_id
    }

    private_subnet.destroy

    if last_subnet
      delete_all_firewall_tag_keys
      delete_firewall_policy
      delete_vpc_network
    end

    pop "subnet destroyed"
  end

  private

  # --- Firewall policy management ---

  def firewall_policy_name
    gcp_vpc_name
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
        Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      ]
    end

    rule_attrs = {
      priority:,
      direction:,
      action:,
      match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(**matcher_attrs)
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
        priority:
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      nil
    end

    if existing
      # If an existing rule at this priority doesn't match our desired state
      # (e.g., priority collision from concurrent allocation), overwrite it with ours.
      # We overwrite (rather than skip) because subnet allow rules only run
      # once during provisioning -- skipping would permanently leave this
      # subnet without egress allow rules, breaking intra-subnet traffic.
      unless policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs: matcher_attrs[:layer4_configs], target_secure_tags:)
        Clog.emit("GCP firewall priority collision, overwriting rule",
          {gcp_priority_collision: {priority:, direction:, action:}})
        credential.network_firewall_policies_client.patch_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          priority:,
          firewall_policy_rule_resource: rule
        )
      end
    else
      begin
        credential.network_firewall_policies_client.add_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          firewall_policy_rule_resource: rule
        )
      rescue ::Google::Cloud::AlreadyExistsError
        # Concurrent strand added this rule -- proceed.
      end
    end
  end

  def policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs:, target_secure_tags: nil)
    existing.direction == direction &&
      existing.action == action &&
      (existing.match&.src_ip_ranges&.to_a || []).sort == (src_ip_ranges || []).sort &&
      (existing.match&.dest_ip_ranges&.to_a || []).sort == (dest_ip_ranges || []).sort &&
      normalize_layer4_configs(existing.match&.layer4_configs&.to_a || []) == normalize_layer4_configs(layer4_configs || []) &&
      existing.target_secure_tags.map(&:name).sort == (target_secure_tags || []).sort
  end

  def normalize_layer4_configs(configs)
    configs.map { |c| [c.ip_protocol, (c.ports&.to_a || []).sort] }.sort
  end

  # --- Destroy helpers ---

  def delete_subnet_policy_rules
    return unless private_subnet.firewall_priority

    subnet_cidrs = [private_subnet.net4.to_s, private_subnet.net6.to_s]
    [subnet_allow_priority, subnet_allow_priority + 1].each do |priority|
      existing = credential.network_firewall_policies_client.get_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:
      )
      # Only delete if the rule belongs to this subnet (avoid deleting
      # another subnet's rule in case of a priority collision)
      next unless existing.match&.dest_ip_ranges&.any? { |r| subnet_cidrs.include?(r) }
      credential.network_firewall_policies_client.remove_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      # Already deleted
    end
  rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
    # Policy already deleted
  end

  def delete_subnet_tag_resources
    tag_key = lookup_tag_key
    return unless tag_key

    resp = credential.crm_client.list_tag_values(parent: tag_key.name)
    subnet_tv = resp.tag_values&.find { |v| v.short_name == subnet_tag_short_name }
    credential.crm_client.delete_tag_value(subnet_tv.name) if subnet_tv

    # Per-subnet tag key -- always delete it when the subnet is destroyed
    credential.crm_client.delete_tag_key(tag_key.name)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 404
  rescue RuntimeError => e
    raise unless e.message.include?("still attached to resources") || e.message.include?("FAILED_PRECONDITION")
    Clog.emit("Tag value still attached to resources, will retry", {tag_value_retry: {tag_key: tag_key.name, error: e.message}})
    nap 15
  end

  def delete_all_firewall_tag_keys
    vpc_network_link = gcp_network_self_link_with_id
    resp = credential.crm_client.list_tag_keys(parent: "projects/#{gcp_project_id}")
    (resp.tag_keys || []).each do |tk|
      next unless tk.short_name.start_with?("ubicloud-fw-") && tk.purpose == "GCE_FIREWALL"
      next unless tk.purpose_data&.dig("network") == vpc_network_link

      # Fire-and-forget: don't wait for CRM LRO -- blocking here locks
      # tag values from other projects, breaking their firewall matching.
      values_resp = credential.crm_client.list_tag_values(parent: tk.name)
      (values_resp.tag_values || []).each { |tv| credential.crm_client.delete_tag_value(tv.name) }

      credential.crm_client.delete_tag_key(tk.name)
    rescue Google::Cloud::Error, Google::Apis::ClientError, RuntimeError => e
      Clog.emit("Failed to delete firewall tag key during VPC cleanup",
        {vpc_cleanup_tag_error: {tag_key: tk.name, error: e.message}})
    end
  rescue Google::Cloud::Error, Google::Apis::ClientError, RuntimeError => e
    Clog.emit("Failed to list tag keys during VPC cleanup",
      {vpc_cleanup_list_tags_error: {error: e.message}})
  end

  def delete_firewall_policy
    # Remove association first, then delete the policy
    begin
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name
      )
      policy.associations.each do |assoc|
        credential.network_firewall_policies_client.remove_association(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          name: assoc.name
        )
      end

      credential.network_firewall_policies_client.delete(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name
      )
    rescue Google::Cloud::NotFoundError
      # Already deleted
    end
  rescue Google::Cloud::Error => e
    Clog.emit("Failed to delete firewall policy during VPC cleanup",
      {vpc_cleanup_policy_error: {policy: firewall_policy_name, error: e.message}})
  end

  def delete_vpc_network
    credential.networks_client.delete(
      project: gcp_project_id,
      network: gcp_vpc_name
    )
  rescue Google::Cloud::NotFoundError
    # Already deleted
  rescue Google::Cloud::InvalidArgumentError => e
    Clog.emit("Failed to delete VPC network during cleanup",
      {vpc_cleanup_network_error: {vpc: gcp_vpc_name, error: e.message}})
  end

  # --- Shared helpers ---

  def subnet_allow_priority
    private_subnet.firewall_priority ||
      raise("subnet firewall_priority not allocated for #{private_subnet.ubid}")
  end

  def allocate_subnet_firewall_priority
    retries = 0
    project_id = private_subnet.project_id
    location_id = private_subnet.location_id
    begin
      used = DB[:private_subnet]
        .where(project_id:, location_id:)
        .exclude(id: private_subnet.id)
        .where(Sequel.~(firewall_priority: nil))
        .select_map(:firewall_priority)
        .to_set

      slot = nil
      (1000..8998).step(2) do |p|
        unless used.include?(p)
          slot = p
          break
        end
      end

      raise "GCP firewall priority range exhausted for project #{project_id}" unless slot

      private_subnet.update(firewall_priority: slot)
    rescue Sequel::UniqueConstraintViolation
      begin
        private_subnet.update(firewall_priority: nil)
      rescue
        nil
      end
      retries += 1
      raise "GCP subnet firewall priority allocation failed after #{retries} concurrent retries" if retries > 5
      retry
    end
  end

  def gcp_vpc_name
    @gcp_vpc_name ||= self.class.vpc_name(private_subnet.project, private_subnet.location)
  end

  def credential
    @credential ||= private_subnet.location.location_credential
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_region
    @gcp_region ||= private_subnet.location.name.delete_prefix("gcp-")
  end

  # --- Secure tag management ---

  def tag_key_short_name
    "ubicloud-subnet-#{private_subnet.ubid}"
  end

  def subnet_tag_short_name
    "member"
  end

  def tag_key_parent
    "projects/#{gcp_project_id}"
  end

  def gcp_network_self_link_with_id
    network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc_name)
    raise "GCP network #{gcp_vpc_name} has no numeric ID" unless network.id.positive?
    "https://www.googleapis.com/compute/v1/projects/#{gcp_project_id}/global/networks/#{network.id}"
  end

  def ensure_tag_key
    if (pending = frame["pending_tag_key_crm_op"])
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_key_crm_op" => nil})
      raise "CRM operation #{pending} failed: #{op.error.message}" if op.error
      name = op.response&.dig("name")
      return name if name
      return lookup_tag_key&.name ||
          raise("Tag key #{tag_key_short_name} created but name not found in operation response or listing")
    end

    tag_key_obj = Google::Apis::CloudresourcemanagerV3::TagKey.new(
      short_name: tag_key_short_name,
      parent: tag_key_parent,
      purpose: "GCE_FIREWALL",
      purpose_data: {"network" => gcp_network_self_link_with_id}
    )

    op = credential.crm_client.create_tag_key(tag_key_obj)
    unless op.done?
      update_stack({"pending_tag_key_crm_op" => op.name})
      nap 5
    end
    raise "CRM operation #{op.name} failed: #{op.error.message}" if op.error
    name = op.response&.dig("name")
    return name if name

    lookup_tag_key&.name ||
      raise("Tag key #{tag_key_short_name} created but name not found in operation response or listing")
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_key&.name || raise("Tag key #{tag_key_short_name} conflict but not found on lookup")
  rescue RuntimeError => e
    raise unless e.message.include?("ALREADY_EXISTS")
    lookup_tag_key&.name || raise("Tag key #{tag_key_short_name} conflict but not found on lookup")
  end

  def lookup_tag_key
    resp = credential.crm_client.list_tag_keys(parent: tag_key_parent)
    resp.tag_keys&.find { |tk| tk.short_name == tag_key_short_name }
  end

  def ensure_tag_value(parent_tag_key_name, short_name)
    if (pending = frame["pending_tag_value_crm_op"])
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_value_crm_op" => nil})
      raise "CRM operation #{pending} failed: #{op.error.message}" if op.error
      name = op.response&.dig("name")
      return name if name
      return lookup_tag_value_name(parent_tag_key_name, short_name) ||
          raise("Tag value #{short_name} created but name not found in operation response or listing")
    end

    tag_value_obj = Google::Apis::CloudresourcemanagerV3::TagValue.new(
      short_name:,
      parent: parent_tag_key_name
    )

    op = credential.crm_client.create_tag_value(tag_value_obj)
    unless op.done?
      update_stack({"pending_tag_value_crm_op" => op.name})
      nap 5
    end
    raise "CRM operation #{op.name} failed: #{op.error.message}" if op.error
    name = op.response&.dig("name")
    return name if name

    lookup_tag_value_name(parent_tag_key_name, short_name) ||
      raise("Tag value #{short_name} created but name not found in operation response or listing")
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_value_name(parent_tag_key_name, short_name) ||
      raise("Tag value #{short_name} conflict but not found on lookup")
  rescue RuntimeError => e
    raise unless e.message.include?("ALREADY_EXISTS")
    lookup_tag_value_name(parent_tag_key_name, short_name) ||
      raise("Tag value #{short_name} conflict but not found on lookup")
  end

  def lookup_tag_value_name(parent_tag_key_name, short_name)
    resp = credential.crm_client.list_tag_values(parent: parent_tag_key_name)
    resp.tag_values&.find { |v| v.short_name == short_name }&.name
  end
end
