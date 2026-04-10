# frozen_string_literal: true

# Mixin for GCP strand programs that manage Network Firewall Policy rules.
#
# Provides idempotent ensure/compare/normalize helpers so the same logic
# is shared across VpcNexus (VPC-wide deny rules) and SubnetNexus
# (per-subnet allow rules).
#
# The including class must provide:
#   credential          — a LocationCredentialGcp (for network_firewall_policies_client)
#   gcp_project_id      — the GCP project ID string
#   firewall_policy_name — the policy to operate on
module GcpFirewallPolicy
  private

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

    begin
      existing = credential.network_firewall_policies_client.get_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:,
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      begin
        credential.network_firewall_policies_client.add_rule(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
          firewall_policy_rule_resource: rule,
        )
      rescue ::Google::Cloud::AlreadyExistsError
        # Concurrent strand added this rule -- proceed.
        nil
      end
    else
      # If an existing rule at this priority doesn't match our desired state
      # (e.g., priority collision from concurrent allocation), overwrite it.
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
    configs.map { |c| [c.ip_protocol, c.ports.to_a.sort] }.sort
  end
end
