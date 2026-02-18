# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vnet::Gcp::SubnetNexus < Prog::Base
  subject_is :private_subnet

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze

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
      op.wait_until_done!
      raise "VPC creation failed: #{op.results.error}" if op.error?
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
          private_ip_google_access: true
        )
      )
      op.wait_until_done!
      raise "Subnet creation failed: #{op.results.error}" if op.error?
    end

    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      private_subnet.vms.each(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end

    nap 10 * 60
  end

  label def destroy
    decr_destroy
    private_subnet.remove_all_firewalls

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      delete_gcp_subnet
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
    op.wait_until_done!
    raise "Firewall rule #{name} creation failed: #{op.results.error}" if op.error?
  end

  def delete_gcp_subnet
    subnet_name = "ubicloud-#{private_subnet.ubid}"
    op = credential.subnetworks_client.delete(
      project: gcp_project_id,
      region: gcp_region,
      subnetwork: subnet_name
    )
    op.wait_until_done!
  rescue Google::Cloud::NotFoundError
    # Already deleted
  end

  def maybe_delete_vpc
    project = private_subnet.project
    remaining = project.private_subnets_dataset.where(
      Sequel.lit("id != ? AND location_id IN (SELECT id FROM location WHERE provider = 'gcp')", private_subnet.id)
    ).count
    return if remaining > 0

    # Last GCP subnet in this project — clean up VPC firewall rules and VPC
    ["#{gcp_vpc_name}-deny-ingress", "#{gcp_vpc_name}-deny-egress"].each do |rule_name|
      op = credential.firewalls_client.delete(project: gcp_project_id, firewall: rule_name)
      op.wait_until_done!
    rescue Google::Cloud::NotFoundError
      # Already deleted
    end

    op = credential.networks_client.delete(project: gcp_project_id, network: gcp_vpc_name)
    op.wait_until_done!
  rescue Google::Cloud::NotFoundError
    # Already deleted
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
end
