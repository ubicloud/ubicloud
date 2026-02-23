# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    rules = vm.firewall_rules.select(&:port_range)
    ip4_rules, ip6_rules = rules.partition { |r| !r.ip6? }

    # GCE firewall rules cannot mix IPv4 and IPv6 source ranges in one rule,
    # so we build separate rules for each address family.
    desired_rules = build_desired_gce_rules(ip4_rules, "ubicloud-fw-#{vm.name}") +
      build_desired_gce_rules(ip6_rules, "ubicloud-fw6-#{vm.name}")
    existing_rules = list_existing_gce_rules

    # Delete rules that are no longer desired
    existing_rules.each do |existing|
      unless desired_rules.any? { |d| d[:name] == existing.name }
        delete_gce_rule(existing.name)
      end
    end

    existing_by_name = existing_rules.each_with_object({}) { |fw, h| h[fw.name] = fw }

    # Create or update desired rules
    desired_rules.each do |desired|
      existing = existing_by_name[desired[:name]]
      if existing
        update_gce_rule(desired) unless gce_rule_matches?(existing, desired)
      else
        create_gce_rule(desired)
      end
    end

    pop "firewall rule is added"
  end

  private

  def build_desired_gce_rules(rules, prefix)
    # Group rules by CIDR to create one GCE rule per source CIDR.
    # Each GCE rule lists all allowed protocol+port combinations for that CIDR.
    rules_by_cidr = rules.group_by { |r| r.cidr.to_s }
    desired = []

    rules_by_cidr.each_with_index do |(cidr, cidr_rules), idx|
      # Build allowed entries grouped by protocol
      allowed_by_proto = cidr_rules.group_by(&:protocol)
      allowed_entries = allowed_by_proto.map do |proto, proto_rules|
        ports = proto_rules.map { |r| format_port_range(r.port_range) }
        {protocol: proto, ports:}
      end

      desired << {
        name: (idx == 0) ? prefix : "#{prefix}-#{idx}",
        source_ranges: [cidr],
        allowed: allowed_entries
      }
    end

    desired
  end

  def gce_rule_matches?(existing, desired)
    existing.source_ranges.to_a.sort == desired[:source_ranges].sort &&
      existing.target_tags.to_a.sort == [vm.name].sort &&
      existing.allowed.length == desired[:allowed].length &&
      desired[:allowed].all? { |d|
        existing.allowed.any? { |e|
          e.I_p_protocol == d[:protocol] && e.ports.to_a.sort == d[:ports].sort
        }
      }
  end

  def format_port_range(port_range)
    from = port_range.begin
    to = port_range.end - 1
    (from == to) ? from.to_s : "#{from}-#{to}"
  end

  def gce_rule_prefixes
    ["ubicloud-fw-#{vm.name}", "ubicloud-fw6-#{vm.name}"]
  end

  def list_existing_gce_rules
    gce_rule_prefixes.flat_map do |prefix|
      firewalls_client.list(
        project: gcp_project_id,
        filter: "name:#{prefix}*"
      ).select { |fw| fw.name.start_with?(prefix) }
    end
  rescue Google::Cloud::Error
    []
  end

  def create_gce_rule(desired)
    firewall_resource = build_firewall_resource(desired)
    op = firewalls_client.insert(
      project: gcp_project_id,
      firewall_resource:
    )
    op.wait_until_done!
  rescue Google::Cloud::AlreadyExistsError
    update_gce_rule(desired)
  end

  def update_gce_rule(desired)
    firewall_resource = build_firewall_resource(desired)
    op = firewalls_client.update(
      project: gcp_project_id,
      firewall: desired[:name],
      firewall_resource:
    )
    op.wait_until_done!
  end

  def delete_gce_rule(name)
    op = firewalls_client.delete(
      project: gcp_project_id,
      firewall: name
    )
    op.wait_until_done!
  rescue Google::Cloud::NotFoundError
    # Already deleted
  end

  def build_firewall_resource(desired)
    allowed = desired[:allowed].map do |entry|
      Google::Cloud::Compute::V1::Allowed.new(
        I_p_protocol: entry[:protocol],
        ports: entry[:ports]
      )
    end

    Google::Cloud::Compute::V1::Firewall.new(
      name: desired[:name],
      network: "projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}",
      direction: "INGRESS",
      priority: 1000,
      source_ranges: desired[:source_ranges],
      target_tags: [vm.name],
      allowed:
    )
  end

  def credential
    @credential ||= vm.location.location_credential
  end

  def firewalls_client
    @firewalls_client ||= credential.firewalls_client
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_vpc_name
    @gcp_vpc_name ||= begin
      ps = vm.nics.first&.private_subnet
      project = ps ? ps.project : vm.project
      Prog::Vnet::Gcp::SubnetNexus.vpc_name(project)
    end
  end
end
