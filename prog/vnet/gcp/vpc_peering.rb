# frozen_string_literal: true

# Runs on the VPC's existing strand, serializing peering mutations and teardown.
# Returning while the peer is inactive keeps firewall reconciliation responsive.
class Prog::Vnet::Gcp::VpcPeering < Prog::Base
  include GcpLro

  subject_is :gcp_vpc

  # Base#before_run pops child frames immediately on destroy. Here the pending
  # cloud operation must drain first; sync then removes the peering before we pop.
  def before_run
  end

  label def sync
    register_deadline(nil, 10 * 60)
    network = credential.networks_client.get(project: gcp_project_id, network: gcp_vpc.name)
    gcp_vpc.lock!(:no_key_update)
    peering = network.peerings.find { it.name == gcp_vpc.peering_name }

    if peering && !(peering.network == gcp_vpc.peer_network || peering.network.end_with?("/#{gcp_vpc.peer_network}"))
      raise "GCP peering #{gcp_vpc.peering_name} points to an unexpected network"
    end

    if removing?
      finish_removal unless peering
      op = credential.networks_client.remove_peering(
        project: gcp_project_id, network: gcp_vpc.name,
        networks_remove_peering_request_resource: Google::Cloud::Compute::V1::NetworksRemovePeeringRequest.new(name: gcp_vpc.peering_name),
      )
    elsif peering
      gcp_vpc.update(peering_state: (peering.state == "ACTIVE") ? "active" : "waiting_for_peer", peering_state_message: peering.state_details)
      pop "peering status refreshed"
    else
      op = credential.networks_client.add_peering(
        project: gcp_project_id, network: gcp_vpc.name,
        networks_add_peering_request_resource: Google::Cloud::Compute::V1::NetworksAddPeeringRequest.new(
          network_peering: Google::Cloud::Compute::V1::NetworkPeering.new(
            name: gcp_vpc.peering_name, network: gcp_vpc.peer_network,
            exchange_subnet_routes: true, stack_type: "IPV4_ONLY",
            import_custom_routes: false, export_custom_routes: false,
            import_subnet_routes_with_public_ip: false, export_subnet_routes_with_public_ip: false,
          ),
        ),
      )
    end

    save_gcp_op("peering_op", op_name: op.name, scope: "global")
    hop_wait_operation
  rescue Google::Cloud::NotFoundError => e
    finish_removal if removing?
    fail_peering(e.message)
  rescue Google::Cloud::AlreadyExistsError, Google::Cloud::AbortedError, Google::Cloud::UnavailableError
    nap 15
  rescue Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError, Google::Cloud::PermissionDeniedError, Google::Cloud::ResourceExhaustedError => e
    # GCP serializes peering operations across both networks, including changes
    # submitted by the customer. These conflicts are temporary, not bad input.
    nap 15 if removing? || e.message.include?("operation in progress")
    fail_peering(e.message)
  end

  label def wait_operation
    hop_sync unless frame["peering_op"]
    poll_and_clear_gcp_op("peering_op") do |op|
      # Commit the clear even on an error: polling a finished failed operation
      # again cannot make progress. A delete retries by re-reading the network.
      clear_gcp_op("peering_op")
      nap 15 if removing? || %w[RESOURCE_NOT_READY INTERNAL_ERROR RATE_LIMIT_EXCEEDED].include?(op_error_code(op))
      fail_peering(op_error_message(op))
    end
    hop_sync
  end

  private

  def removing?
    gcp_vpc.peering_state == "deleting" || destroy_set? || destroying_set?
  end

  def finish_removal
    gcp_vpc.update(peer_network: nil, peering_state: nil, peering_state_message: nil)
    pop "peering removed"
  end

  def fail_peering(message)
    gcp_vpc.lock!(:no_key_update)
    hop_sync if removing?
    gcp_vpc.update(peering_state: "failed", peering_state_message: message)
    pop "peering failed"
  end

  def credential
    @credential ||= gcp_vpc.location.location_credential_gcp
  end

  def gcp_project_id
    credential.project_id
  end
end
