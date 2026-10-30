# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::Test::VpcPeering < Prog::Test::PostgresBase
  semaphore :pause, :destroy
  frame_accessor :customer_account_id, :customer_vpc_id, :customer_subnet_id, :vpc_peering_id,
    :peering_connection_id, :client_instance_id, :label_deadlines, :cascade_peering

  # Ubicloud AWS subnets are /16s drawn only from 10/8 and 172.16/12.
  CUSTOMER_CIDR = "192.168.240.0/24"
  CLIENT_INSTANCE_TYPE = "t4g.nano"
  CLIENT_AMI_NAME = "al2023-ami-2023.*-arm64"
  CLIENT_RESULT = /ubie2e result addrs=([\d.,]+|none) tcp=(ok|fail)/
  CONNECTION_FINAL_STATUSES = %w[deleting deleted rejected failed expired].freeze

  def self.assemble
    super(provider: "aws", project_name: "Vpc-Peering-Test-Project")
  end

  label def start
    location = Prog::LocationNexus.assemble(display_name: "vpc-peering-e2e", name: aws_location_name, ui_name: "vpc-peering-e2e",
      visible: true, provider: "aws", project_id: postgres_test_project_id, byoc: true).subject
    Prog::Test::Base.ensure_aws_e2e_credential(location)
    target_vm_size, target_storage_size_gib = self.class.aws_postgres_test_size

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: postgres_test_project_id,
      location_id: location.id,
      name: "postgres-test-vpc-peering",
      target_vm_size:,
      target_storage_size_gib:,
    )

    self.location_id = location.id
    self.postgres_resource_id = st.id
    self.private_subnet_id = st.subject.private_subnet_id
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    nap 10 unless postgres_resource.strand.label == "wait" && representative_server.run_query("SELECT 1") == "1"
    hop_create_customer_vpc
  end

  label def create_customer_vpc
    vpc = client.describe_vpcs(filters: [{name: "tag:Name", values: [customer_resource_name]}]).vpcs.first ||
      client.create_vpc(cidr_block: CUSTOMER_CIDR, tag_specifications: Util.aws_tag_specifications("vpc", customer_resource_name)).vpc
    self.customer_vpc_id = vpc.vpc_id
    self.customer_account_id = vpc.owner_id
    hop_wait_customer_vpc
  end

  label def wait_customer_vpc
    nap 5 if client.describe_vpcs(filters: [{name: "vpc-id", values: [customer_vpc_id]}, {name: "state", values: ["available"]}]).vpcs.empty?
    # AWS takes one VPC attribute per call.
    client.modify_vpc_attribute(vpc_id: customer_vpc_id, enable_dns_support: {value: true})
    client.modify_vpc_attribute(vpc_id: customer_vpc_id, enable_dns_hostnames: {value: true})
    hop_create_customer_subnet
  end

  label def create_customer_subnet
    subnet = client.describe_subnets(filters: [{name: "vpc-id", values: [customer_vpc_id]}]).subnets.first ||
      client.create_subnet(vpc_id: customer_vpc_id, cidr_block: CUSTOMER_CIDR, availability_zone_id: representative_server.vm.aws_instance.az_id,
        tag_specifications: Util.aws_tag_specifications("subnet", customer_resource_name)).subnet
    self.customer_subnet_id = subnet.subnet_id
    hop_request_peering
  end

  label def request_peering
    st = Prog::Vnet::VpcPeeringNexus.assemble(private_subnet, peer_account_id: customer_account_id, peer_vpc_id: customer_vpc_id,
      aws: {peer_region: aws_location_name})
    self.vpc_peering_id = st.id
    hop_wait_peering_requested
  end

  label def wait_peering_requested
    case vpc_peering.state
    when "waiting_for_peer"
      self.peering_connection_id = vpc_peering.vpc_peering_aws_resource.peering_connection_id
      hop_accept_peering
    when "failed"
      record_failure("VPC peering failed: #{vpc_peering.state_message}")
    else
      wait_or_fail(5 * 60, "VPC peering was not requested within 5 minutes, state #{vpc_peering.state}")
    end
    hop_destroy
  end

  label def accept_peering
    begin
      client.accept_vpc_peering_connection(vpc_peering_connection_id: peering_connection_id)
    rescue Aws::EC2::Errors::InvalidStateTransition
      # No longer pending acceptance; wait_peering_active judges the state.
      nil
    end
    hop_wait_peering_active
  end

  label def wait_peering_active
    case vpc_peering.state
    when "active"
      if (failure = active_peering_failure)
        # EC2 reads are eventually consistent.
        wait_or_fail(5 * 60, failure)
      elsif cascade_peering
        hop_destroy_peered_postgres
      else
        hop_add_customer_route
      end
    when "failed"
      record_failure("VPC peering failed: #{vpc_peering.state_message}")
    else
      wait_or_fail(5 * 60, "VPC peering did not become active within 5 minutes, state #{vpc_peering.state}")
    end
    hop_destroy
  end

  label def add_customer_route
    route_table = client.describe_route_tables(filters: [{name: "vpc-id", values: [customer_vpc_id]}, {name: "association.main", values: ["true"]}]).route_tables.first
    begin
      client.create_route(route_table_id: route_table.route_table_id, destination_cidr_block: private_subnet.net4.to_s, vpc_peering_connection_id: peering_connection_id)
    rescue Aws::EC2::Errors::RouteAlreadyExists
      nil
    end
    hop_launch_client
  end

  label def launch_client
    image = client.describe_images(owners: ["amazon"], filters: [{name: "name", values: [CLIENT_AMI_NAME]}]).images.max_by(&:creation_date)
    if image.nil?
      record_failure("No Amazon Linux image matches #{CLIENT_AMI_NAME}")
      hop_destroy
    end

    begin
      instance = client.run_instances(
        image_id: image.image_id,
        instance_type: CLIENT_INSTANCE_TYPE,
        min_count: 1,
        max_count: 1,
        subnet_id: customer_subnet_id,
        user_data: Base64.strict_encode64(client_user_data),
        instance_initiated_shutdown_behavior: "terminate",
        metadata_options: {http_tokens: "required"},
        client_token: "#{strand.ubid}-client",
        tag_specifications: Util.aws_tag_specifications("instance", customer_resource_name) + Util.aws_tag_specifications("volume", customer_resource_name),
      ).instances.first
    rescue Aws::EC2::Errors::ServiceError => e
      # The launch parameters are fixed, so a refusal (capacity, limits, image) would repeat until the job times out.
      record_failure("Could not launch the client instance: #{e.code}: #{e.message}")
      hop_destroy
    end
    self.client_instance_id = instance.instance_id
    hop_wait_client_result
  end

  label def wait_client_result
    output = begin
      client.get_console_output(instance_id: client_instance_id, latest: true).output
    rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
      # RunInstances is eventually consistent.
      nil
    end
    addrs, tcp = Base64.decode64(output.to_s).scan(CLIENT_RESULT).last

    if tcp.nil?
      wait_or_fail(15 * 60, "Client instance #{client_instance_id} reported no result within 15 minutes")
    elsif tcp == "fail" || addrs.split(",").any? { !private_subnet.net4.contains(NetAddr::IPv4.parse(it)) }
      record_failure("From the peer VPC, #{postgres_hostname} resolved to #{addrs} and TCP to port 5432 got #{tcp}, expected addresses in #{private_subnet.net4} and ok")
    end
    hop_destroy
  end

  label def destroy
    if client_instance_id
      begin
        client.terminate_instances(instance_ids: [client_instance_id])
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
        nil
      end
    end

    if (peering = vpc_peering)
      self.peering_connection_id = peering.vpc_peering_aws_resource.peering_connection_id
      peering.incr_destroy
    end

    hop_wait_peering_destroyed
  end

  label def wait_peering_destroyed
    if vpc_peering
      wait_or_fail(10 * 60) { "VPC peering was not destroyed within 10 minutes, it is #{peering_progress}" }
    elsif peering_connection_id
      verify_connection_gone("the VPC peering was destroyed")

      unless (routes = peering_routes).empty?
        record_failure("Route table #{route_table_id} still routes #{routes.map(&:destination_cidr_block)} through #{peering_connection_id}")
      end
    end

    # A second peering stays active so that the PostgreSQL destroy has to remove it.
    if fail_message.nil? && !cascade_peering
      self.cascade_peering = true
      self.label_deadlines = nil
      hop_request_peering
    end

    hop_wait_client_terminated
  end

  label def destroy_peered_postgres
    self.timeline_ids = postgres_resource.servers_dataset.distinct.select_map(:timeline_id)
    postgres_resource.incr_destroy
    hop_wait_peering_cascade
  end

  label def wait_peering_cascade
    if vpc_peering
      wait_or_fail(20 * 60) { "VPC peering was not destroyed within 20 minutes of the PostgreSQL destroy, it is #{peering_progress}" }
    end
    verify_connection_gone("the PostgreSQL destroy")
    hop_wait_client_terminated
  end

  label def wait_client_terminated
    if client_instance_id
      instance = client.describe_instances(filters: [{name: "instance-id", values: [client_instance_id]}]).reservations.flat_map(&:instances).first
      if instance && instance.state.name != "terminated"
        wait_or_fail(5 * 60, "Client instance #{client_instance_id} did not terminate within 5 minutes")
        hop_destroy_postgres
      end
    end
    hop_delete_customer_subnet
  end

  label def delete_customer_subnet
    if customer_subnet_id
      begin
        client.delete_subnet(subnet_id: customer_subnet_id)
      rescue Aws::EC2::Errors::InvalidSubnetIDNotFound
        nil
      rescue Aws::EC2::Errors::DependencyViolation
        wait_or_fail(5 * 60, "Customer subnet #{customer_subnet_id} could not be deleted within 5 minutes")
        hop_destroy_postgres
      end
    end
    hop_delete_customer_vpc
  end

  label def delete_customer_vpc
    if customer_vpc_id
      begin
        client.delete_vpc(vpc_id: customer_vpc_id)
      rescue Aws::EC2::Errors::InvalidVpcIDNotFound
        nil
      rescue Aws::EC2::Errors::DependencyViolation
        wait_or_fail(5 * 60, "Customer VPC #{customer_vpc_id} could not be deleted within 5 minutes")
      end
    end
    hop_destroy_postgres
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    nap_if_private_subnet
    verify_timelines_destroyed(timeline_ids) if timeline_ids
    hop_destroy_location
  end

  label def destroy_location
    Location[location_id].incr_destroy
    hop_wait_location_destroyed
  end

  label def wait_location_destroyed
    nap 5 if Location[location_id]
    hop_finish
  end

  def client
    @client ||= Location[location_id].location_credential_aws.client
  end

  def private_subnet
    @private_subnet ||= PrivateSubnet[private_subnet_id]
  end

  def vpc_peering
    @vpc_peering ||= ::VpcPeering[vpc_peering_id]
  end

  def route_table_id
    private_subnet.private_subnet_aws_resource.route_table_id
  end

  # The database hostname is a CNAME to this name. The CI account has no DNS zone, so the client resolves the target.
  def postgres_hostname
    representative_server.vm.aws_instance.ipv4_dns_name
  end

  def customer_resource_name
    "vpc-peering-e2e-#{strand.ubid}"
  end

  def verify_connection_gone(after)
    pcx = describe_peering_connection
    unless pcx.nil? || CONNECTION_FINAL_STATUSES.include?(pcx.status.code)
      record_failure("Peering connection #{peering_connection_id} is #{pcx.status.code} after #{after}")
      begin
        client.delete_vpc_peering_connection(vpc_peering_connection_id: peering_connection_id)
      rescue Aws::EC2::Errors::InvalidVpcPeeringConnectionIDNotFound, Aws::EC2::Errors::InvalidStateTransition
        nil
      end
    end
  end

  def describe_peering_connection
    client.describe_vpc_peering_connections(vpc_peering_connection_ids: [peering_connection_id]).vpc_peering_connections.first
  rescue Aws::EC2::Errors::InvalidVpcPeeringConnectionIDNotFound
    nil
  end

  def peering_routes
    client.describe_route_tables(route_table_ids: [route_table_id]).route_tables.first.routes.select { it.vpc_peering_connection_id == peering_connection_id }
  end

  def active_peering_failure
    routes = peering_routes.map { [it.destination_cidr_block, it.state] }
    if vpc_peering.peer_cidrs.map(&:to_s) != [CUSTOMER_CIDR]
      "VPC peering routes #{vpc_peering.peer_cidrs.map(&:to_s)}, expected [#{CUSTOMER_CIDR}]"
    elsif routes != [[CUSTOMER_CIDR, "active"]]
      "Route table #{route_table_id} has #{routes} through #{peering_connection_id}, expected an active route to #{CUSTOMER_CIDR}"
    elsif !describe_peering_connection.requester_vpc_info.peering_options.allow_dns_resolution_from_remote_vpc
      "Peering connection #{peering_connection_id} does not allow DNS resolution from the peer VPC"
    # A settled wait naps 15 minutes; a raising one backs off with try above 0.
    elsif (pst = Strand[vpc_peering_id]).label != "wait" || pst.try != 0 || pst.schedule < Time.now + 5 * 60
      "VPC peering has not settled in wait, it is in #{pst.label} (try #{pst.try})"
    elsif vpc_peering.state_message
      "VPC peering is active with warnings: #{vpc_peering.state_message}"
    end
  end

  # The peering can finish between the caller's existence check and this read.
  def peering_progress
    "#{vpc_peering.display_state} in #{Strand[vpc_peering_id]&.label}"
  end

  def record_failure(message)
    self.fail_message = fail_message ? "#{fail_message}; #{message}" : message
  end

  def wait_or_fail(seconds, message = nil)
    deadlines = label_deadlines || {}
    unless (deadline = deadlines[strand.label])
      deadline = Time.now.to_i + seconds
      self.label_deadlines = deadlines.merge(strand.label => deadline)
    end
    nap 5 if Time.now.to_i < deadline
    record_failure(message || yield)
  end

  # The client has no public address, so it reports through the serial console.
  def client_user_data
    <<~SH
      #!/bin/bash
      shutdown -h +60
      host=#{postgres_hostname.shellescape}
      for i in $(seq 30); do
        addrs=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u | paste -sd, -)
        tcp=fail
        [ -n "$addrs" ] && timeout 5 bash -c "exec 3<>/dev/tcp/${addrs%%,*}/5432" && tcp=ok
        [ "$tcp" = ok ] && break
        sleep 10
      done
      echo "ubie2e result addrs=${addrs:-none} tcp=$tcp" >/dev/console
    SH
  end
end
