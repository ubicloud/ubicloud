# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../../lib/gcp_lro"

class Prog::Vnet::Gcp::NicNexus < Prog::Base
  include GcpLro

  subject_is :nic

  VM_STRIDE = 64
  VM_BASE = 10000
  VM_MAX = 59999

  label def start
    register_deadline("wait", 5 * 60)

    ps = nic.private_subnet
    location_id = ps.location_id
    nic_resource = NicGcpResource.create_with_id(
      nic.id,
      network_name: Prog::Vnet::Gcp::SubnetNexus.vpc_name(ps.location),
      subnet_name: "ubicloud-#{ps.ubid}"
    )
    allocate_vm_firewall_priority(nic_resource, location_id)

    hop_allocate_static_ip
  end

  label def allocate_static_ip
    address_name = "ubicloud-#{nic.name}"

    begin
      addr = addresses_client.get(project: gcp_project_id, region: gcp_region, address: address_name)
      nic.nic_gcp_resource.update(address_name:, static_ip: addr.address)
      hop_wait
    rescue Google::Cloud::NotFoundError
      # Address does not exist yet, reserve it
    end

    address_resource = Google::Cloud::Compute::V1::Address.new(
      name: address_name,
      address_type: "EXTERNAL",
      network_tier: "STANDARD"
    )

    op = addresses_client.insert(
      project: gcp_project_id,
      region: gcp_region,
      address_resource:
    )
    save_gcp_op(op.name, "region", gcp_region)
    update_stack({"gcp_address_name" => address_name})
    hop_wait_allocate_ip
  end

  label def wait_allocate_ip
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    address_name = frame["gcp_address_name"]
    if op_error?(op)
      begin
        addresses_client.get(project: gcp_project_id, region: gcp_region, address: address_name)
        Clog.emit("GCP LRO error but resource exists",
          {gcp_lro_recovered: {resource: "static IP #{address_name}", error: op_error_message(op)}})
      rescue Google::Cloud::NotFoundError
        raise "GCP static IP #{address_name} creation failed: #{op_error_message(op)}"
      end
    end

    clear_gcp_op
    addr = addresses_client.get(project: gcp_project_id, region: gcp_region, address: address_name)
    nic.nic_gcp_resource.update(address_name:, static_ip: addr.address)

    hop_wait
  end

  label def wait
    nap 6 * 60 * 60
  end

  label def destroy
    decr_destroy
    release_static_ip
    nic.nic_gcp_resource&.destroy
    nic.destroy
    pop "nic deleted"
  end

  private

  def credential
    @credential ||= nic.private_subnet.location.location_credential
  end

  def addresses_client
    @addresses_client ||= credential.addresses_client
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_region
    @gcp_region ||= nic.private_subnet.location.name.delete_prefix("gcp-")
  end

  def release_static_ip
    address_name = nic.nic_gcp_resource&.address_name
    return unless address_name

    addresses_client.delete(project: gcp_project_id, region: gcp_region, address: address_name)
  rescue Google::Cloud::NotFoundError
    # Already released
  end

  def allocate_vm_firewall_priority(nic_resource, location_id)
    used = DB[:nic_gcp_resource]
      .where(location_id:)
      .exclude(id: nic_resource.id)
      .where(Sequel.~(firewall_base_priority: nil))
      .select_map(:firewall_base_priority)
      .to_set

    slot = nil
    (VM_BASE..VM_MAX).step(VM_STRIDE) do |p|
      unless used.include?(p)
        slot = p
        break
      end
    end

    raise "GCP VM firewall priority range exhausted for location #{location_id}" unless slot

    nic_resource.update(firewall_base_priority: slot, location_id:)
  rescue Sequel::UniqueConstraintViolation
    begin
      nic_resource.update(firewall_base_priority: nil)
    rescue
      nil
    end
    retry
  end
end
