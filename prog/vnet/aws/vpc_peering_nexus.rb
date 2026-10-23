# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::Vnet::Aws::VpcPeeringNexus < Prog::Base
  subject_is :vpc_peering, :vpc_peering_aws_resource

  FINAL_STATUSES = %w[deleted rejected failed expired].freeze
  GONE_STATUSES = %w[deleting deleted rejected failed expired].freeze
  DELETABLE_STATUSES = %w[pending-acceptance active].freeze
  QUOTA_ERRORS = [
    Aws::EC2::Errors::OutstandingVpcPeeringConnectionLimitExceeded,
    Aws::EC2::Errors::PendingVpcPeeringConnectionLimitExceeded,
  ].freeze
  PEER_INPUT_ERRORS = [
    Aws::EC2::Errors::InvalidVpcIDNotFound,
    Aws::EC2::Errors::InvalidParameterValue,
  ].freeze
  PEER_LIMIT_ERRORS = [
    Aws::EC2::Errors::ActiveVpcPeeringConnectionPerVpcLimitExceeded,
    Aws::EC2::Errors::VpcPeeringConnectionsPerVpcLimitExceeded,
  ].freeze
  RFC1918_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16].map { NetAddr::IPv4Net.parse(it) }.freeze

  label def start
    hop_destroy if private_subnet.destroying_set?
    register_deadline("wait_acceptance", 15 * 60, allow_extension: true)
    nap 10 unless private_subnet.strand.label == "wait"
    hop_create_connection
  end

  label def create_connection
    pcx = find_connection || begin
      client.create_vpc_peering_connection(
        vpc_id: ps_aws.vpc_id,
        peer_vpc_id: vpc_peering.peer_vpc_id,
        peer_owner_id: vpc_peering.peer_account_id,
        peer_region: vpc_peering_aws_resource.peer_region,
        tag_specifications: Util.aws_tag_specifications("vpc-peering-connection", private_subnet.name, {"ubid" => vpc_peering.ubid}),
      ).vpc_peering_connection
    rescue Aws::EC2::Errors::VpcPeeringConnectionAlreadyExists
      existing_pair_connection
    rescue *QUOTA_ERRORS => e
      quota_exceeded(e)
    rescue Aws::EC2::Errors::OptInRequired => e
      fail_peering("Ubicloud cannot peer with VPCs in #{vpc_peering_aws_resource.peer_region} yet. Delete this peering, or peer a VPC in another region. AWS said: #{e.message}")
    rescue *PEER_INPUT_ERRORS => e
      raise unless names_peer_input?(e)
      fail_peering("AWS refused the peering request. Check the account ID, VPC ID and region, then delete this peering and create it again. AWS said: #{e.message}")
    rescue *PEER_LIMIT_ERRORS => e
      raise unless names_peer_input?(e)
      fail_peering("VPC #{vpc_peering.peer_vpc_id} has reached its AWS limit of peering connections. Delete one of them in AWS or raise the limit, then delete this peering and create it again. AWS said: #{e.message}")
    end
    record_connection(pcx)
    if !location.byoc && pcx.requester_vpc_info.owner_id == vpc_peering.peer_account_id
      fail_peering("Account #{vpc_peering.peer_account_id} is Ubicloud's own AWS account. Delete this peering and create it again with the ID of the AWS account that owns your VPC.")
    end
    hop_wait_connection_created
  end

  label def wait_connection_created
    pcx = describe_connection
    nap 5 if pcx.nil? || pcx.status.code == "initiating-request"
    vpc_peering.update(state: "waiting_for_peer")
    hop_wait_acceptance
  end

  label def wait_acceptance
    pcx = describe_connection
    case pcx&.status&.code
    when "pending-acceptance"
      vpc_peering_aws_resource.update(expires_at: pcx.expiration_time)
      nap acceptance_poll_interval
    when "initiating-request"
      nap 5
    when "provisioning"
      register_deadline("wait", 15 * 60)
      nap 5
    when "active"
      register_deadline("wait", 15 * 60)
      cidrs = accepter_cidrs(pcx)
      nap 5 if cidrs.empty?
      claim_peer_cidrs(cidrs)
      if vpc_peering.peer_cidrs.empty?
        fail_peering("None of the CIDR blocks of VPC #{vpc_peering.peer_vpc_id} (#{cidrs.join(", ")}) can be routed. Ubicloud routes only private (RFC 1918) CIDR blocks that no other VPC peering of this private subnet already routes. Delete this peering, then create it again once no other peering routes those blocks, or peer a VPC with other private CIDR blocks.")
      end
      vpc_peering.update(state: "configuring")
      hop_configure
    when nil
      expires_at = vpc_peering_aws_resource.expires_at
      nap acceptance_poll_interval if expires_at && Time.now < expires_at
      fail_peering("The peering connection #{pcx_id} no longer exists in AWS. Delete this peering and create it again.")
    else
      other = find_connection
      if other && !FINAL_STATUSES.include?(other.status.code) && other.vpc_peering_connection_id != pcx_id
        record_connection(other)
        unregister_deadline("wait")
        nap 5
      end
      fail_peering(acceptance_failure_reason(pcx))
    end
  end

  label def configure
    pcx = describe_connection
    fail_peering(connection_deleted_reason) if connection_gone?(pcx)
    nap 5 unless pcx.status.code == "active"
    desired = vpc_peering.peer_cidrs.map(&:to_s).sort
    current = routed_cidrs
    unless current == desired
      (current - desired).each { delete_route(destination_cidr_block: it) }
      (desired - current).each { create_route(it) }
      nap 5
    end
    dns_ok = ensure_dns_resolution(pcx)
    vpc_peering.update(state: "active", state_message: active_warnings(accepter_cidrs(pcx), dns_ok))
    hop_wait
  end

  label def wait
    pcx = describe_connection
    fail_peering(connection_deleted_reason) if connection_gone?(pcx)
    nap 5 unless pcx.status.code == "active"
    if vpc_peering.state != "active"
      register_deadline("wait", 15 * 60)
      hop_configure
    end
    routes = routed_cidrs
    cidrs = accepter_cidrs(pcx)
    claimed = !cidrs.empty? && claim_peer_cidrs(cidrs)
    if claimed || routes != vpc_peering.peer_cidrs.map(&:to_s).sort
      vpc_peering.update(state: "configuring")
      nap 5
    end
    dns_ok = ensure_dns_resolution(pcx)
    vpc_peering.update(state_message: active_warnings(cidrs, dns_ok))
    nap 15 * 60
  end

  label def destroy
    decr_destroy
    register_deadline(nil, 15 * 60)
    hop_remove_routes
  end

  label def remove_routes
    if pcx_id
      peering_routes.each do |route|
        delete_route(**route.to_h.slice(:destination_cidr_block, :destination_ipv_6_cidr_block, :destination_prefix_list_id))
      end
    end
    vpc_peering.update(peer_cidrs: Sequel.pg_array([], :cidr))
    hop_delete_connection
  end

  label def delete_connection
    live = teardown_connections
    live.each do |pcx|
      next unless DELETABLE_STATUSES.include?(pcx.status.code)
      delete_peering_connection(pcx.vpc_peering_connection_id)
    end
    nap 5 unless live.empty?
    destroying_set? ? hop_finish : hop_failed
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

  def ps_aws
    @ps_aws ||= private_subnet.private_subnet_aws_resource
  end

  def location
    @location ||= private_subnet.location
  end

  def client
    @client ||= location.location_credential_aws.client
  end

  def pcx_id
    vpc_peering_aws_resource.peering_connection_id
  end

  def describe_connection
    client.describe_vpc_peering_connections(vpc_peering_connection_ids: [pcx_id]).vpc_peering_connections.first
  rescue Aws::EC2::Errors::InvalidVpcPeeringConnectionIDNotFound
    nil
  end

  def connection_gone?(pcx)
    pcx.nil? || GONE_STATUSES.include?(pcx.status.code)
  end

  def tagged_connections
    client.describe_vpc_peering_connections(filters: [{name: "tag:ubid", values: [vpc_peering.ubid]}]).flat_map(&:vpc_peering_connections)
  end

  def find_connection
    tagged = tagged_connections.reject { %w[deleted deleting].include?(it.status.code) }
    tagged.find { !FINAL_STATUSES.include?(it.status.code) } || tagged.first
  end

  def existing_pair_connection
    ours, peer = ps_aws.vpc_id, vpc_peering.peer_vpc_id
    live = client.describe_vpc_peering_connections(filters: [
      {name: "requester-vpc-info.vpc-id", values: [ours, peer]},
      {name: "accepter-vpc-info.vpc-id", values: [ours, peer]},
    ]).flat_map(&:vpc_peering_connections).reject { connection_gone?(it) }
    if (pcx = live.find { it.requester_vpc_info.vpc_id == ours })
      pcx
    elsif (pcx = live.find { it.requester_vpc_info.vpc_id == peer })
      if pcx.status.code == "pending-acceptance"
        begin
          client.reject_vpc_peering_connection(vpc_peering_connection_id: pcx.vpc_peering_connection_id)
        rescue Aws::EC2::Errors::InvalidStateTransition
          nil
        end
        nap 5
      end
      fail_peering("A peering connection between VPC #{peer} and this Ubicloud VPC already exists (#{pcx.vpc_peering_connection_id}), requested from your account. Delete it in AWS, then delete this peering and create it again.")
    else
      nap 5
    end
  end

  def names_peer_input?(e)
    [vpc_peering.peer_vpc_id, vpc_peering.peer_account_id].any? { e.message.include?(it) }
  end

  def quota_exceeded(e)
    if location.byoc
      fail_peering("The AWS account of this location has reached its limit of VPC peering requests. Accept or delete pending requests in that account, then delete this peering and create it again. AWS said: #{e.message}")
    end
    Clog.emit("VPC peering quota exceeded", {vpc_peering_quota_exceeded: {ubid: vpc_peering.ubid, location: location.ubid, error_code: e.code}})
    vpc_peering.update(state_message: "Ubicloud has reached the AWS limit for pending peering requests in this region. The request is sent automatically when capacity frees up.")
    register_deadline("wait_acceptance", 60 * 60, allow_extension: 60 * 60, page: "warning")
    nap 5 * 60
  end

  def record_connection(pcx)
    vpc_peering_aws_resource.update(peering_connection_id: pcx.vpc_peering_connection_id,
      requester_account_id: pcx.requester_vpc_info.owner_id, expires_at: pcx.expiration_time)
    vpc_peering.update(state_message: nil)
  end

  def acceptance_failure_reason(pcx)
    case pcx.status.code
    when "failed"
      "AWS could not establish the peering connection (#{pcx.status.message}). Check the account ID, VPC ID and region, and that no CIDR block of your VPC overlaps #{private_subnet.net4}. Delete this peering and create it again."
    when "rejected"
      "The peering request was rejected in AWS account #{vpc_peering.peer_account_id}. Delete this peering and create it again."
    when "expired"
      "The peering request expired before it was accepted. Delete this peering and create it again."
    else
      "The peering request was deleted in AWS before it was accepted. Delete this peering and create it again."
    end
  end

  def acceptance_poll_interval
    (Time.now - vpc_peering.created_at < 60 * 60) ? 30 : 5 * 60
  end

  def accepter_cidrs(pcx)
    pcx.accepter_vpc_info.cidr_block_set.map(&:cidr_block).sort
  end

  # Holds the subnet lock until the label ends, so callers read AWS first; only wait's DNS option update follows it.
  def claim_peer_cidrs(cidrs)
    private_subnet.lock!(:no_key_update)
    taken = private_subnet.vpc_peerings_dataset.exclude(id: vpc_peering.id).select_map(:peer_cidrs).flatten
    routable = cidrs.select { routable_cidr?(NetAddr::IPv4Net.parse(it), taken) }
    return false if routable == vpc_peering.peer_cidrs.map(&:to_s)
    vpc_peering.update(peer_cidrs: Sequel.pg_array(routable, :cidr))
    true
  end

  def routable_cidr?(net, taken)
    RFC1918_RANGES.any? { [0, -1].include?(net.rel(it)) } &&
      control_plane_nets.none? { net.rel(it) } &&
      taken.none? { net.rel(it) }
  end

  def control_plane_nets
    @control_plane_nets ||= Config.control_plane_outbound_cidrs.reject { it == "0.0.0.0/0" }.map { NetAddr.parse_net(it) }.grep(NetAddr::IPv4Net)
  end

  def peering_routes
    client.describe_route_tables(filters: [
      {name: "route-table-id", values: [ps_aws.route_table_id]},
      {name: "route.vpc-peering-connection-id", values: [pcx_id]},
    ]).flat_map(&:route_tables).flat_map(&:routes).select { it.vpc_peering_connection_id == pcx_id }
  end

  def routed_cidrs
    peering_routes.filter_map(&:destination_cidr_block).sort
  end

  def delete_route(**dest)
    client.delete_route(route_table_id: ps_aws.route_table_id, **dest)
  rescue Aws::EC2::Errors::InvalidRouteNotFound
    nil
  end

  def create_route(cidr)
    client.create_route(route_table_id: ps_aws.route_table_id, destination_cidr_block: cidr, vpc_peering_connection_id: pcx_id)
  rescue Aws::EC2::Errors::RouteAlreadyExists
    existing = client.describe_route_tables(filters: [
      {name: "route-table-id", values: [ps_aws.route_table_id]},
      {name: "route.destination-cidr-block", values: [cidr]},
    ]).flat_map(&:route_tables).flat_map(&:routes).find { it.destination_cidr_block == cidr }
    if existing.nil?
      nap 5
    elsif existing.vpc_peering_connection_id == pcx_id
      nil
    elsif existing.state == "blackhole"
      client.replace_route(route_table_id: ps_aws.route_table_id, destination_cidr_block: cidr, vpc_peering_connection_id: pcx_id)
    else
      fail "Route to #{cidr} in #{ps_aws.route_table_id} already targets #{existing.vpc_peering_connection_id || existing.gateway_id}"
    end
  end

  def ensure_dns_resolution(pcx)
    return true if pcx.requester_vpc_info.peering_options&.allow_dns_resolution_from_remote_vpc
    client.modify_vpc_peering_connection_options(vpc_peering_connection_id: pcx_id,
      requester_peering_connection_options: {allow_dns_resolution_from_remote_vpc: true})
    true
  rescue Aws::EC2::Errors::InvalidVpcPeeringConnectionStateDnsHostnamesDisabled
    false
  end

  def active_warnings(accepter, dns_ok)
    unrouted = accepter - vpc_peering.peer_cidrs.map(&:to_s)
    msgs = []
    msgs << "Not routed: #{unrouted.join(", ")}. Ubicloud routes only private (RFC 1918) CIDR blocks that no other VPC peering of this private subnet already routes." unless unrouted.empty?
    msgs << "Private DNS is off: turn on DNS hostnames and DNS resolution for VPC #{vpc_peering.peer_vpc_id}. Until then the database hostname resolves to its public address from your VPC and traffic does not use the peering. Ubicloud retries every 15 minutes." unless dns_ok
    msgs.empty? ? nil : msgs.join(" ")
  end

  def connection_deleted_reason
    "The peering connection #{pcx_id} was deleted in AWS. Traffic no longer flows. Delete this peering and create it again to reconnect."
  end

  def fail_peering(reason)
    vpc_peering.update(state: "failed", state_message: reason)
    register_deadline("failed", 15 * 60)
    hop_remove_routes
  end

  def teardown_connections
    conns = tagged_connections
    if pcx_id && conns.none? { it.vpc_peering_connection_id == pcx_id } && (recorded = describe_connection)
      conns << recorded
    end
    conns.reject { FINAL_STATUSES.include?(it.status.code) }
  end

  def delete_peering_connection(id)
    client.delete_vpc_peering_connection(vpc_peering_connection_id: id)
  rescue Aws::EC2::Errors::InvalidVpcPeeringConnectionIDNotFound, Aws::EC2::Errors::InvalidStateTransition
    nil
  end
end
