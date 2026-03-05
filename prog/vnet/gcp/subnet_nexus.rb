# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../../lib/gcp_lro"

class Prog::Vnet::Gcp::SubnetNexus < Prog::Base
  include GcpLro

  subject_is :private_subnet

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  # GCE internal IPv6 ranges used by dual-stack subnets (ULA space)
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze

  # Priority assignments for firewall policy rules.
  # Lower number = higher priority. Range: 0–65535.
  # Layout: subnet-allow EGRESS 1000..8999, VM INGRESS 10000..59999, deny 65531..65534
  DENY_RULE_BASE_PRIORITY = 65534
  ALLOW_SUBNET_BASE_PRIORITY = 1000

  def self.vpc_name(location)
    "ubicloud-#{location.name}"
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
        raise "GCP VPC #{gcp_vpc_name} creation failed: #{op_error_message(op)}"
      end
    end

    clear_gcp_op
    hop_create_firewall_policy
  end

  label def create_firewall_policy
    ensure_firewall_policy
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

    hop_create_subnet_allow_rules
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
    hop_create_subnet_allow_rules
  end

  label def create_subnet_allow_rules
    allocate_subnet_firewall_priority unless private_subnet.firewall_priority

    # Allow same-subnet IPv4 egress (overrides the VPC-wide deny-egress)
    ensure_policy_rule(
      priority: subnet_allow_priority,
      direction: "EGRESS",
      action: "allow",
      src_ip_ranges: [private_subnet.net4.to_s],
      dest_ip_ranges: [private_subnet.net4.to_s],
      layer4_configs: [{ip_protocol: "all"}]
    )

    # Allow same-subnet IPv6 egress (overrides VPC-wide deny-egress-ipv6)
    ensure_policy_rule(
      priority: subnet_allow_priority + 1,
      direction: "EGRESS",
      action: "allow",
      src_ip_ranges: [private_subnet.net6.to_s],
      dest_ip_ranges: [private_subnet.net6.to_s],
      layer4_configs: [{ip_protocol: "all"}]
    )

    hop_wait
  end

  label def wait
    when_refresh_keys_set? do
      # GCP has no IPsec tunnels — nothing to rekey, just clear the semaphore
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

      unless delete_gcp_subnet
        # GCE subnet still in use by a terminating instance — retry
        nap 5
      end
      private_subnet.destroy
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap rand(5..10)
    end
  end

  private

  # --- Firewall policy management ---

  def firewall_policy_name
    gcp_vpc_name
  end

  def ensure_firewall_policy
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
        wait_for_compute_global_op(op)
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
    return if policy.associations&.any? { |a| a.attachment_target == vpc_target }

    begin
      assoc_op = credential.network_firewall_policies_client.add_association(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_association_resource: Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
          name: gcp_vpc_name,
          attachment_target: vpc_target
        )
      )
      wait_for_compute_global_op(assoc_op)
    rescue Google::Cloud::AlreadyExistsError
      # Association created by a concurrent strand — proceed.
    rescue Google::Cloud::InvalidArgumentError => e
      if e.message.include?("already exists")
        # GCP returns InvalidArgumentError (not AlreadyExistsError) when the
        # association name is already taken — proceed.
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

  def ensure_policy_rule(priority:, direction:, action:, src_ip_ranges: nil, dest_ip_ranges: nil, layer4_configs: nil)
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

    rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
      priority:,
      direction:,
      action:,
      match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(**matcher_attrs)
    )

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
      # once during provisioning — skipping would permanently leave this
      # subnet without egress allow rules, breaking intra-subnet traffic.
      unless policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs: matcher_attrs[:layer4_configs])
        Clog.emit("GCP firewall priority collision, overwriting rule",
          {gcp_priority_collision: {priority:, direction:, action:}})
        op = credential.network_firewall_policies_client.patch_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          priority:,
          firewall_policy_rule_resource: rule
        )
        wait_for_compute_global_op(op)
      end
    else
      op = credential.network_firewall_policies_client.add_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_rule_resource: rule
      )
      wait_for_compute_global_op(op)
    end
  end

  def policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs:)
    existing.direction == direction &&
      existing.action == action &&
      (existing.match&.src_ip_ranges&.to_a || []).sort == (src_ip_ranges || []).sort &&
      (existing.match&.dest_ip_ranges&.to_a || []).sort == (dest_ip_ranges || []).sort &&
      normalize_layer4_configs(existing.match&.layer4_configs&.to_a || []) == normalize_layer4_configs(layer4_configs || [])
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
      op = credential.network_firewall_policies_client.remove_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:
      )
      wait_for_compute_global_op(op)
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      # Already deleted
    end
  rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
    # Policy already deleted
  end

  def delete_gcp_subnet
    subnet_name = "ubicloud-#{private_subnet.ubid}"
    op = credential.subnetworks_client.delete(
      project: gcp_project_id,
      region: gcp_region,
      subnetwork: subnet_name
    )
    wait_for_compute_regional_op(op, gcp_region)
    true
  rescue Google::Cloud::NotFoundError
    true # Already deleted
  rescue Google::Cloud::InvalidArgumentError => e
    raise unless e.message.include?("being used by")
    Clog.emit("GCP subnet still in use, retrying", {gcp_subnet_in_use: {subnet: subnet_name, error: e.message}})
    false
  end

  # --- Shared helpers ---

  def subnet_allow_priority
    private_subnet.firewall_priority or
      raise "subnet firewall_priority not allocated for #{private_subnet.ubid}"
  end

  def allocate_subnet_firewall_priority
    retries = 0
    location_id = private_subnet.location_id
    begin
      used = DB[:private_subnet]
        .where(location_id:)
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

      raise "GCP firewall priority range exhausted for location #{location_id}" unless slot

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
    @gcp_vpc_name ||= self.class.vpc_name(private_subnet.location)
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
end
