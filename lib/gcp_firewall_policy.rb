# frozen_string_literal: true

require "google/cloud/compute/v1"

module GcpFirewallPolicy
  V1 = Google::Cloud::Compute::V1

  # Short name for the single tag value under every tag key Ubicloud
  # creates - both subnet membership tags and per-firewall tags carry
  # this value. Each tag value is namespaced under its tag key, so the
  # short name is just an identifier slot, not a relationship label.
  TAG_VALUE = "active"

  private

  def ensure_firewall_policy_rule(priority:, direction:, action:, layer4_configs:, src_ip_ranges: nil, dest_ip_ranges: nil, target_secure_tags: nil)
    matcher_attrs = {}
    matcher_attrs[:src_ip_ranges] = src_ip_ranges if src_ip_ranges
    matcher_attrs[:dest_ip_ranges] = dest_ip_ranges if dest_ip_ranges
    matcher_attrs[:layer4_configs] = layer4_configs.map { |cfg|
      V1::FirewallPolicyRuleMatcherLayer4Config.new(**cfg)
    }

    rule_attrs = {
      priority:,
      direction:,
      action:,
      match: V1::FirewallPolicyRuleMatcher.new(**matcher_attrs),
    }

    if target_secure_tags
      rule_attrs[:target_secure_tags] = target_secure_tags.map { |t|
        V1::FirewallPolicyRuleSecureTag.new(name: t)
      }
    end

    rule = V1::FirewallPolicyRule.new(**rule_attrs)

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
        # Concurrent strand added this rule. Proceed.
        nil
      end
    else
      # If an existing rule at this priority doesn't match our desired state
      # (e.g., priority collision from concurrent allocation), overwrite it.
      unless firewall_policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs: matcher_attrs[:layer4_configs], target_secure_tags:)
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

  def firewall_policy_rule_matches_desired?(existing, direction:, action:, src_ip_ranges:, dest_ip_ranges:, layer4_configs:, target_secure_tags: nil)
    match = existing.match
    existing.direction == direction &&
      existing.action == action &&
      sorted_ranges_eq?(match&.src_ip_ranges, src_ip_ranges) &&
      sorted_ranges_eq?(match&.dest_ip_ranges, dest_ip_ranges) &&
      normalize_layer4_configs(match&.layer4_configs&.to_a) == normalize_layer4_configs(layer4_configs) &&
      existing.target_secure_tags.map(&:name).sort == (target_secure_tags&.sort || [].freeze)
  end

  def sorted_ranges_eq?(existing_ranges, desired_ranges)
    (existing_ranges&.to_a&.sort || [].freeze) == (desired_ranges&.sort || [].freeze)
  end

  def normalize_layer4_configs(configs)
    configs&.map { |c| [c.ip_protocol, c.ports.to_a.sort] }&.sort! || [].freeze
  end
end
