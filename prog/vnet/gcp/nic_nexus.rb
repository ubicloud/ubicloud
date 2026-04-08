# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../../lib/gcp_lro"

class Prog::Vnet::Gcp::NicNexus < Prog::Base
  include GcpLro

  subject_is :nic

  label def start
    register_deadline("wait", 5 * 60)

    # Record which VPC and subnet this NIC belongs to. The VPC is per (project, location)
    # and the subnet maps 1:1 to an Ubicloud PrivateSubnet. Firewall rules and tag bindings
    # are managed separately by UpdateFirewallRules when the VM is provisioned.
    ps = nic.private_subnet
    NicGcpResource.create_with_id(
      nic.id,
      network_name: ps.gcp_vpc.name,
      subnet_name: "ubicloud-#{ps.ubid}"
    )

    hop_allocate_static_ip
  end

  label def allocate_static_ip
    # GCP resource names must be 1-63 chars, lowercase alphanumeric + hyphens.
    # NIC names are "{vm_ubid}-nic" (30 chars) so this is always safe (39 chars).
    address_name = "ubicloud-#{nic.name}"
    fail "GCP address name too long: #{address_name.length} chars" if address_name.length > 63

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

    begin
      op = addresses_client.insert(
        project: gcp_project_id,
        region: gcp_region,
        address_resource:
      )
    rescue Google::Cloud::AlreadyExistsError
      addr = addresses_client.get(project: gcp_project_id, region: gcp_region, address: address_name)
      nic.nic_gcp_resource.update(address_name:, static_ip: addr.address)
      hop_wait
    end
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

    address_name = nic.nic_gcp_resource&.address_name
    if address_name
      begin
        op = addresses_client.delete(project: gcp_project_id, region: gcp_region, address: address_name)
        save_gcp_op(op.name, "region", gcp_region)
        hop_wait_release_ip
      rescue Google::Cloud::NotFoundError
        # Already released
      end
    end

    nic.nic_gcp_resource&.destroy
    nic.destroy
    pop "nic deleted"
  end

  label def wait_release_ip
    op = poll_gcp_op
    nap 5 unless op.status == :DONE

    raise "GCP static IP deletion failed: #{op_error_message(op)}" if op_error?(op)

    clear_gcp_op
    nic.nic_gcp_resource&.destroy
    nic.destroy
    pop "nic deleted"
  end

  private

  def credential
    @credential ||= nic.private_subnet.location.location_credential_gcp
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
end
