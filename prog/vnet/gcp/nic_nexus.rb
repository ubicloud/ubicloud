# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vnet::Gcp::NicNexus < Prog::Base
  subject_is :nic

  GCP_ZONE_SUFFIXES = ["a", "b", "c"].freeze

  label def start
    register_deadline("wait", 5 * 60)

    available = GCP_ZONE_SUFFIXES - (frame["exclude_availability_zones"] || [])
    zone_suffix = frame["availability_zone"] || available.sample || "a"
    current_frame = strand.stack.first
    current_frame["gcp_zone_suffix"] = zone_suffix
    strand.modified!(:stack)
    strand.save_changes

    NicGcpResource.create_with_id(nic.id)

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
    check_lro!(op, "static IP #{address_name}") {
      addresses_client.get(project: gcp_project_id, region: gcp_region, address: address_name)
    }

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

    op = addresses_client.delete(project: gcp_project_id, region: gcp_region, address: address_name)
    op.wait_until_done!
    raise "GCP static IP release failed: #{lro_error_message(op)}" if op.error?
  rescue Google::Cloud::NotFoundError
    # Already released
  end

  def check_lro!(op, resource_description)
    op.wait_until_done!
    return unless op.error?

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
