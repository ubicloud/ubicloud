# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../../lib/gcp_lro"

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  include GcpLro

  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    rules = vm.firewall_rules.select(&:port_range)
    ip4_rules, ip6_rules = rules.partition { |r| !r.ip6? }

    ip4_desired = build_desired_policy_rules(ip4_rules, ip6: false)
    ip6_desired = build_desired_policy_rules(ip6_rules, ip6: true, priority_offset: ip4_desired.length)
    desired_rules = ip4_desired + ip6_desired

    vm_stride = Prog::Vnet::Gcp::NicNexus::VM_STRIDE
    if desired_rules.length > vm_stride
      raise "VM #{vm.name} exceeds VM_STRIDE=#{vm_stride} firewall rules (#{desired_rules.length})"
    end

    existing_rules = list_existing_vm_policy_rules

    # Delete rules that are no longer desired
    existing_rules.each do |existing|
      unless desired_rules.any? { |d| d[:priority] == existing.priority }
        delete_policy_rule(existing.priority)
      end
    end

    existing_by_priority = existing_rules.each_with_object({}) { |r, h| h[r.priority] = r }

    # Create or update desired rules
    desired_rules.each do |desired|
      existing = existing_by_priority[desired[:priority]]
      if existing
        update_policy_rule(desired) unless policy_rule_matches?(existing, desired)
      else
        create_policy_rule(desired)
      end
    end

    pop "firewall rule is added"
  end

  private

  def build_desired_policy_rules(rules, ip6:, priority_offset: 0)
    return [] if rules.empty?

    rules_by_cidr = rules.group_by { |r| r.cidr.to_s }
    desired = []

    rules_by_cidr.each_with_index do |(cidr, cidr_rules), idx|
      layer4_configs = cidr_rules.group_by(&:protocol).map do |proto, proto_rules|
        ports = proto_rules.map { |r| format_port_range(r.port_range) }
        {ip_protocol: proto, ports:}
      end

      desired << {
        priority: vm_rule_base_priority + priority_offset + idx,
        source_ranges: [cidr],
        dest_ip_range: ip6 ? vm_dest_ipv6_range : vm_dest_ip_range,
        layer4_configs:
      }
    end

    desired
  end

  def policy_rule_matches?(existing, desired)
    matcher = existing.match
    return false unless matcher

    matcher.src_ip_ranges.to_a.sort == desired[:source_ranges].sort &&
      matcher.dest_ip_ranges.to_a == [desired[:dest_ip_range]] &&
      matcher.layer4_configs.length == desired[:layer4_configs].length &&
      desired[:layer4_configs].all? { |d|
        matcher.layer4_configs.any? { |e|
          e.ip_protocol == d[:ip_protocol] && e.ports.to_a.sort == d[:ports].sort
        }
      }
  end

  def format_port_range(port_range)
    from = port_range.begin
    to = port_range.end - 1
    (from == to) ? from.to_s : "#{from}-#{to}"
  end

  def vm_rule_base_priority
    @vm_rule_base_priority ||= begin
      base = vm.nics.first&.nic_gcp_resource&.firewall_base_priority
      raise "VM #{vm.name} NIC has no firewall_base_priority allocated" unless base
      base
    end
  end

  def vm_private_ip
    @vm_private_ip ||= vm.nics.first&.private_ipv4&.network&.to_s
  end

  def vm_dest_ip_range
    "#{vm_private_ip}/32"
  end

  def vm_private_ipv6
    @vm_private_ipv6 ||= vm.nics.first&.private_ipv6&.network&.to_s
  end

  def vm_dest_ipv6_range
    vm_private_ipv6 ? "#{vm_private_ipv6}/128" : vm_dest_ip_range
  end

  def list_existing_vm_policy_rules
    return [] unless vm_private_ip

    policy = credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name
    )

    vm_dest_ranges = [vm_dest_ip_range, vm_dest_ipv6_range].compact.uniq

    (policy.rules || []).select { |rule|
      rule.direction == "INGRESS" && rule.action == "allow" &&
        rule.match&.dest_ip_ranges&.any? { |r| vm_dest_ranges.include?(r) }
    }
  rescue Google::Cloud::Error
    []
  end

  def create_policy_rule(desired)
    rule = build_policy_rule(desired)
    op = begin
      credential.network_firewall_policies_client.add_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_rule_resource: rule
      )
    rescue Google::Cloud::AlreadyExistsError, Google::Cloud::InvalidArgumentError
      # Only update if the existing rule belongs to this VM (check dest IP).
      # If another VM owns this priority (hash collision), log and skip.
      existing = credential.network_firewall_policies_client.get_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority: desired[:priority]
      )
      vm_dest_ranges = [vm_dest_ip_range, vm_dest_ipv6_range].compact.uniq
      if existing.match&.dest_ip_ranges&.any? { |r| vm_dest_ranges.include?(r) }
        update_policy_rule(desired)
      else
        Clog.emit("GCP firewall priority collision, skipping update",
          {gcp_priority_collision: {vm: vm.name, priority: desired[:priority]}})
      end
      return
    end
    wait_for_compute_global_op(op)
  end

  def update_policy_rule(desired)
    rule = build_policy_rule(desired)
    op = credential.network_firewall_policies_client.patch_rule(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
      priority: desired[:priority],
      firewall_policy_rule_resource: rule
    )
    wait_for_compute_global_op(op)
  end

  def delete_policy_rule(priority)
    op = begin
      credential.network_firewall_policies_client.remove_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      return # Already deleted
    end
    wait_for_compute_global_op(op)
  end

  def build_policy_rule(desired)
    layer4_configs = desired[:layer4_configs].map do |cfg|
      Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(
        ip_protocol: cfg[:ip_protocol],
        ports: cfg[:ports]
      )
    end

    Google::Cloud::Compute::V1::FirewallPolicyRule.new(
      priority: desired[:priority],
      direction: "INGRESS",
      action: "allow",
      match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
        src_ip_ranges: desired[:source_ranges],
        dest_ip_ranges: [desired[:dest_ip_range]],
        layer4_configs:
      )
    )
  end

  def credential
    @credential ||= vm.location.location_credential
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def firewall_policy_name
    @firewall_policy_name ||= Prog::Vnet::Gcp::SubnetNexus.vpc_name(vm.location)
  end
end
