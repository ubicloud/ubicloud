# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vnet::Gcp::VpcPeeringNexus < Prog::Base
  include GcpLro

  subject_is :vpc_peering, :vpc_peering_gcp_resource

  RETRYABLE_OP_ERRORS = %w[RESOURCE_NOT_READY INTERNAL_ERROR RATE_LIMIT_EXCEEDED].freeze
  LIMIT_OP_ERRORS = %w[QUOTA_EXCEEDED LIMIT_EXCEEDED].freeze
  TRANSIENT_ERRORS = [
    Google::Cloud::ResourceExhaustedError,
    Google::Cloud::UnavailableError,
    Google::Cloud::InternalError,
    Google::Cloud::DeadlineExceededError,
  ].freeze
  REFUSED_ERRORS = [
    Google::Cloud::AlreadyExistsError,
    Google::Cloud::InvalidArgumentError,
    Google::Cloud::FailedPreconditionError,
    Google::Cloud::NotFoundError,
  ].freeze
  TRANSIENT_MESSAGES = ["operation in progress", "is not ready"].freeze

  label def start
    hop_destroy if private_subnet.destroying_set?
    register_deadline("wait", 15 * 60, allow_extension: true)
    nap 10 unless private_subnet.strand.label == "wait"
    hop_add_peering
  end

  label def add_peering
    op = begin
      networks_client.add_peering(
        project: gcp_project_id,
        network: network_name,
        networks_add_peering_request_resource: Google::Cloud::Compute::V1::NetworksAddPeeringRequest.new(
          network_peering: Google::Cloud::Compute::V1::NetworkPeering.new(
            name: peering_name,
            network: vpc_peering.peer_vpc_id,
            exchange_subnet_routes: true,
            stack_type: "IPV4_ONLY",
            import_custom_routes: false,
            export_custom_routes: false,
            import_subnet_routes_with_public_ip: false,
            export_subnet_routes_with_public_ip: false,
          ),
        ),
      )
    rescue *TRANSIENT_ERRORS
      nap 15
    rescue Google::Cloud::PermissionDeniedError => e
      record_add_delay(e.message)
      nap 5 * 60
    rescue *REFUSED_ERRORS => e
      add_refused(e)
    end
    Clog.emit("GCP network peering created", {gcp_network_peering_created: "#{peering_name}@#{network_name}"})
    save_gcp_op("add_peering", op_name: op.name, scope: "global")
    hop_wait_add_peering
  end

  label def wait_add_peering
    poll_and_clear_gcp_op("add_peering") do |op|
      clear_gcp_op("add_peering")
      message = op_error_message(op)
      if (peering = our_peering)
        check_peer_network!(peering)
        Clog.emit("GCP LRO error but resource exists", {gcp_lro_recovered: {resource: "network peering #{peering_name}", error: message}})
        hop_wait_peering_created
      end
      nap_hop(15, :add_peering) if transient_op_error?(op)
      if LIMIT_OP_ERRORS.include?(op_error_code(op))
        record_add_delay(message)
        nap_hop(5 * 60, :add_peering)
      end
      fail_peering("GCP could not add Ubicloud's side of the peering with network #{peer_network} in project #{peer_project}. #{overlap_hint} Delete this peering and create it again. GCP said: #{message}")
    end
    hop_wait_peering_created
  end

  label def wait_peering_created
    nap 5 unless (peering = our_peering)
    check_peer_network!(peering)
    vpc_peering.update(state_message: nil) if vpc_peering.state_message
    hop_wait
  end

  label def wait
    unless (peering = our_peering)
      fail_peering("Ubicloud's side of the peering (#{peering_name}) no longer exists in GCP, so traffic does not flow. Delete this peering and create it again.")
    end
    check_peer_network!(peering)

    if peering.state == "ACTIVE"
      unless vpc_peering.state == "active"
        vpc_peering.update(state: "active", state_message: nil)
        register_deadline("wait", 15 * 60)
        hop_refresh_peer_cidrs
      end
      update_peer_cidrs
    elsif vpc_peering.state == "active"
      vpc_peering.update(state: "waiting_for_peer", peer_cidrs: Sequel.pg_array([], :cidr),
        state_message: "Your side of the peering in project #{peer_project} is missing or inactive, so traffic does not flow. Create it again with the command below, or delete this peering. GCP said: #{peering.state_details}")
    elsif vpc_peering.state == "creating"
      vpc_peering.update(state: "waiting_for_peer")
    end

    nap poll_interval
  end

  label def refresh_peer_cidrs
    update_peer_cidrs
    hop_wait
  end

  label def destroy
    decr_destroy
    register_deadline(nil, 15 * 60)
    hop_remove_peering
  end

  label def remove_peering
    %w[add_peering remove_peering].each { poll_and_clear_gcp_op(it) {} if frame[it] }
    finish_teardown unless (vpc = private_subnet.gcp_vpc)

    op = begin
      networks_client.remove_peering(
        project: gcp_project_id,
        network: vpc.name,
        networks_remove_peering_request_resource: Google::Cloud::Compute::V1::NetworksRemovePeeringRequest.new(name: peering_name),
      )
    rescue Google::Cloud::NotFoundError
      finish_teardown
    rescue *TRANSIENT_ERRORS => e
      remove_retry(e.message)
    rescue Google::Cloud::InvalidArgumentError, Google::Cloud::FailedPreconditionError => e
      remove_retry(e.message) if transient_message?(e.message)
      finish_teardown if half_removed?
      raise e
    end
    save_gcp_op("remove_peering", op_name: op.name, scope: "global")
    hop_wait_remove_peering
  end

  label def wait_remove_peering
    poll_and_clear_gcp_op("remove_peering") do |op|
      clear_gcp_op("remove_peering")
      finish_teardown if !transient_op_error?(op) && half_removed?
      Clog.emit("GCP VPC peering removal failed, will retry", {gcp_vpc_peering_remove_retry: {ubid: vpc_peering.ubid, error: op_error_message(op)}})
      nap_hop(15, :remove_peering)
    end
    finish_teardown
  end

  label def finish
    vpc_peering.destroy
    pop "vpc peering destroyed"
  end

  label def failed
    hibernate
  end

  def private_subnet
    @private_subnet ||= vpc_peering.private_subnet
  end

  def location
    @location ||= private_subnet.location
  end

  def credential
    @credential ||= location.location_credential_gcp
  end

  def gcp_project_id
    credential.project_id
  end

  def gcp_region
    location.name.delete_prefix("gcp-")
  end

  def networks_client
    credential.networks_client
  end

  def network_name
    private_subnet.gcp_vpc.name
  end

  def peering_name
    vpc_peering_gcp_resource.peering_name
  end

  def peer_project
    vpc_peering.peer_account_id
  end

  def peer_network
    vpc_peering.peer_vpc_id.split("/").last
  end

  def our_peering
    networks_client.get(project: gcp_project_id, network: network_name).peerings.find { it.name == peering_name }
  end

  def check_peer_network!(peering)
    expected = vpc_peering.peer_vpc_id
    return if peering.network == expected || peering.network.end_with?("/#{expected}")
    raise "GCP peering #{peering_name} on #{network_name} points to #{peering.network}, not #{expected}"
  end

  def half_removed?
    our_peering.nil?
  rescue Google::Cloud::NotFoundError
    true
  end

  def transient_message?(message)
    TRANSIENT_MESSAGES.any? { message.include?(it) }
  end

  def transient_op_error?(op)
    code = op_error_code(op)
    RETRYABLE_OP_ERRORS.include?(code) || transient_message?(op_error_message(op)) || (code.nil? && op.http_error_status_code >= 500)
  end

  def add_refused(e)
    nap 15 if transient_message?(e.message)
    if (peering = our_peering)
      check_peer_network!(peering)
      hop_wait_peering_created
    end
    nap 5 if e.is_a?(Google::Cloud::AlreadyExistsError) || e.message.include?(peering_name)
    raise e if e.message.include?("already a peering")
    fail_peering("GCP refused the peering with network #{peer_network} in project #{peer_project}. Check the project ID and network name. #{overlap_hint} Delete this peering and create it again. GCP said: #{e.message}")
  end

  def overlap_hint
    taken = private_subnet.vpc_peerings_dataset.exclude(id: vpc_peering.id).select_map(:peer_cidrs).flatten
    siblings = taken.empty? ? "" : ", the ranges of this subnet's other peerings (#{taken.join(", ")})"
    "No subnet range of your network may overlap #{private_subnet.net4}#{siblings}, or the subnets of networks peered with yours."
  end

  def record_add_delay(message)
    Clog.emit("GCP refused to add a VPC peering, will retry", {gcp_vpc_peering_add_delayed: {ubid: vpc_peering.ubid, error: message}})
    vpc_peering.update(state_message: "Ubicloud could not add its side of the peering yet and retries every 5 minutes. GCP said: #{message}")
  end

  def remove_retry(message)
    Clog.emit("GCP refused to remove a VPC peering, will retry", {gcp_vpc_peering_remove_retry: {ubid: vpc_peering.ubid, error: message}})
    nap 15
  end

  def update_peer_cidrs
    cidrs = networks_client.list_peering_routes(project: gcp_project_id, network: network_name, peering_name:, direction: "INCOMING", region: gcp_region)
      .filter_map { it.dest_range if it.type == "SUBNET_PEERING_ROUTE" && it.imported && !it.dest_range.include?(":") }
      .uniq.sort
    return if cidrs == vpc_peering.peer_cidrs.map(&:to_s).sort
    vpc_peering.update(peer_cidrs: Sequel.pg_array(cidrs, :cidr))
  end

  def poll_interval
    first_hour = Time.now - vpc_peering.created_at < 60 * 60
    if vpc_peering.state == "active"
      (first_hour && vpc_peering.peer_cidrs.empty?) ? 60 : 15 * 60
    else
      first_hour ? 60 : 5 * 60
    end
  end

  def finish_teardown
    vpc_peering.update(peer_cidrs: Sequel.pg_array([], :cidr)) unless vpc_peering.peer_cidrs.empty?
    destroying_set? ? hop_finish : hop_failed
  end

  def fail_peering(reason)
    vpc_peering.update(state: "failed", state_message: reason)
    register_deadline("failed", 15 * 60)
    hop_remove_peering
  end
end
