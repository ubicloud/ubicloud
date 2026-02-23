# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vnet::Gcp::SubnetNexus < Prog::Base
  subject_is :private_subnet

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  # GCE internal IPv6 ranges used by dual-stack subnets (ULA space)
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze

  def self.vpc_name(project)
    "ubicloud-proj-#{project.ubid}"
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
      check_lro!(op, "VPC #{gcp_vpc_name}") {
        credential.networks_client.get(project: gcp_project_id, network: gcp_vpc_name)
      }
    end

    hop_create_vpc_firewall_rules
  end

  label def create_vpc_firewall_rules
    ensure_deny_rule(
      name: "#{gcp_vpc_name}-deny-ingress",
      direction: "INGRESS",
      source_ranges: RFC1918_RANGES,
      destination_ranges: nil
    )

    ensure_deny_rule(
      name: "#{gcp_vpc_name}-deny-egress",
      direction: "EGRESS",
      source_ranges: nil,
      destination_ranges: RFC1918_RANGES
    )

    ensure_deny_rule(
      name: "#{gcp_vpc_name}-deny-ingress-ipv6",
      direction: "INGRESS",
      source_ranges: GCE_INTERNAL_IPV6_RANGES,
      destination_ranges: nil
    )

    ensure_deny_rule(
      name: "#{gcp_vpc_name}-deny-egress-ipv6",
      direction: "EGRESS",
      source_ranges: nil,
      destination_ranges: GCE_INTERNAL_IPV6_RANGES
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
      check_lro!(op, "subnet #{subnet_name}") {
        credential.subnetworks_client.get(project: gcp_project_id, region: gcp_region, subnetwork: subnet_name)
      }
    end

    hop_create_subnet_allow_rules
  end

  label def create_subnet_allow_rules
    # Allow same-subnet egress (overrides the VPC-wide deny-egress at 65534)
    # Uses subnet-specific tag so only VMs in this subnet match, not all VMs in VPC
    ensure_allow_rule(
      name: subnet_allow_rule_name("egress"),
      direction: "EGRESS",
      source_ranges: nil,
      destination_ranges: [private_subnet.net4.to_s],
      target_tags: [subnet_tag],
      allowed: [Google::Cloud::Compute::V1::Allowed.new(I_p_protocol: "all")]
    )

    # Ingress is NOT allowed at subnet level — per-VM firewall rules control
    # all ingress. This matches metal (iptables) and AWS (security groups)
    # where ingress is denied by default.

    # Allow same-subnet IPv6 egress (overrides VPC-wide deny-egress-ipv6)
    ensure_allow_rule(
      name: subnet_allow_rule_name("egress-ipv6"),
      direction: "EGRESS",
      source_ranges: nil,
      destination_ranges: [private_subnet.net6.to_s],
      target_tags: [subnet_tag],
      allowed: [Google::Cloud::Compute::V1::Allowed.new(I_p_protocol: "all")]
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
      unless delete_gcp_subnet
        # GCE subnet still in use by a terminating instance — retry
        nap 5
      end
      maybe_delete_vpc
      private_subnet.destroy
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      private_subnet.load_balancers.map { |lb| lb.incr_destroy }
      nap rand(5..10)
    end
  end

  private

  def ensure_deny_rule(name:, direction:, source_ranges:, destination_ranges:)
    credential.firewalls_client.get(project: gcp_project_id, firewall: name)
  rescue Google::Cloud::NotFoundError
    attrs = {
      name:,
      network: "projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}",
      direction:,
      priority: 65534,
      target_tags: ["ubicloud-vm"],
      denied: [Google::Cloud::Compute::V1::Denied.new(I_p_protocol: "all")]
    }
    attrs[:source_ranges] = source_ranges if source_ranges
    attrs[:destination_ranges] = destination_ranges if destination_ranges

    fw = Google::Cloud::Compute::V1::Firewall.new(**attrs)
    op = credential.firewalls_client.insert(project: gcp_project_id, firewall_resource: fw)
    check_lro!(op, "firewall rule #{name}") {
      credential.firewalls_client.get(project: gcp_project_id, firewall: name)
    }
  end

  def ensure_allow_rule(name:, direction:, source_ranges:, destination_ranges:, allowed:, target_tags: ["ubicloud-vm"])
    credential.firewalls_client.get(project: gcp_project_id, firewall: name)
  rescue Google::Cloud::NotFoundError
    attrs = {
      name:,
      network: "projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}",
      direction:,
      priority: 1000,
      target_tags:,
      allowed:
    }
    attrs[:source_ranges] = source_ranges if source_ranges
    attrs[:destination_ranges] = destination_ranges if destination_ranges

    fw = Google::Cloud::Compute::V1::Firewall.new(**attrs)
    op = credential.firewalls_client.insert(project: gcp_project_id, firewall_resource: fw)
    check_lro!(op, "firewall rule #{name}") {
      credential.firewalls_client.get(project: gcp_project_id, firewall: name)
    }
  end

  def delete_gcp_subnet
    subnet_name = "ubicloud-#{private_subnet.ubid}"
    op = credential.subnetworks_client.delete(
      project: gcp_project_id,
      region: gcp_region,
      subnetwork: subnet_name
    )
    op.wait_until_done!
    raise "GCP subnet delete failed: #{lro_error_message(op)}" if op.error?
    true
  rescue Google::Cloud::NotFoundError
    true # Already deleted
  rescue Google::Cloud::InvalidArgumentError => e
    raise unless e.message.include?("being used by")
    Clog.emit("GCP subnet still in use, retrying", {gcp_subnet_in_use: {subnet: subnet_name, error: e.message}})
    false
  end

  def maybe_delete_vpc
    project = private_subnet.project
    remaining = project.private_subnets_dataset.where(
      Sequel.lit("id != ? AND location_id IN (SELECT id FROM location WHERE provider = 'gcp')", private_subnet.id)
    ).count
    return if remaining > 0

    # Last GCP subnet in this project — clean up all firewall rules and VPC
    delete_all_vpc_firewall_rules
    delete_vpc_network
  end

  def delete_all_vpc_firewall_rules
    rules = credential.firewalls_client.list(project: gcp_project_id, filter: "network=\"https://www.googleapis.com/compute/v1/projects/#{gcp_project_id}/global/networks/#{gcp_vpc_name}\"")
    rules.each do |rule|
      op = credential.firewalls_client.delete(project: gcp_project_id, firewall: rule.name)
      op.wait_until_done!
    rescue Google::Cloud::NotFoundError
      # Already deleted
    end
  rescue Google::Cloud::NotFoundError
    # VPC or rules already gone
  end

  def delete_vpc_network
    op = credential.networks_client.delete(project: gcp_project_id, network: gcp_vpc_name)
    op.wait_until_done!
  rescue Google::Cloud::NotFoundError
    # Already deleted
  end

  def subnet_allow_rule_name(direction)
    # GCP firewall rule names max 63 chars; use short prefix + subnet ubid
    "ubicloud-allow-#{direction}-#{private_subnet.ubid}"[0, 63]
  end

  def subnet_tag
    "ps-#{private_subnet.ubid}"
  end

  def gcp_vpc_name
    @gcp_vpc_name ||= self.class.vpc_name(private_subnet.project)
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

  def check_lro!(op, resource_description)
    op.wait_until_done!
    return unless op.error?

    # LRO reported an error — check if the resource was created anyway
    begin
      yield
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: resource_description, error: lro_error_message(op)}})
    rescue Google::Cloud::NotFoundError
      raise "GCP #{resource_description} creation failed: #{lro_error_message(op)}"
    end
  end

  def lro_error_message(op)
    err = op.error
    return err.to_s unless err.respond_to?(:code)
    "#{err.message} (code: #{err.code})"
  end
end
