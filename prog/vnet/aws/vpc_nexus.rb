# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Vnet::Aws::VpcNexus < Prog::Base
  subject_is :private_subnet
  frame_accessor :reconcile_vpc_try

  # describe_vpcs is eventually consistent, so an orphan vpc created in the
  # crash window may not be visible immediately. Retry this many times before
  # concluding nothing was created, instead of finishing on a single empty
  # read and orphaning a real vpc.
  RECONCILE_VPC_MAX_TRIES = 6

  label def start
    # PrivateSubnetAwsResource and AwsSubnet records are created in SubnetNexus.assemble
    # Reuse the vpc by the unique subnet tag, never the shared Name: subnet
    # names are unique only per project on a shared AWS account, so a Name match
    # could adopt a foreign subnet's vpc and then drive teardown of its subnets,
    # gateway, and the vpc itself.
    vpc_response = client.describe_vpcs({filters: [{name: "tag:SubnetUbid", values: [private_subnet.ubid]}]})

    vpc_id = if vpc_response.vpcs.empty?
      client.create_vpc({cidr_block: private_subnet.net4.to_s,
        amazon_provided_ipv_6_cidr_block: true,
        tag_specifications: Util.aws_tag_specifications("vpc", private_subnet.name, {"SubnetUbid" => private_subnet.ubid})}).vpc.vpc_id
    else
      vpc_response.vpcs.first.vpc_id
    end

    private_subnet_aws_resource.update(vpc_id:)
    hop_wait_vpc_created
  end

  label def wait_vpc_created
    vpc = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).vpcs[0]

    nap 1 unless vpc.state == "available"

    client.modify_vpc_attribute({
      vpc_id: vpc.vpc_id,
      enable_dns_hostnames: {value: true},
    })

    security_group_response = begin
      client.create_security_group({
        group_name: "aws-#{location.name}-#{private_subnet.ubid}",
        description: "Security group for aws-#{location.name}-#{private_subnet.ubid}",
        vpc_id: private_subnet_aws_resource.vpc_id,
        tag_specifications: Util.aws_tag_specifications("security-group", private_subnet.name),
      })
    rescue Aws::EC2::Errors::InvalidGroupDuplicate
      client.describe_security_groups({filters: [{name: "group-name", values: ["aws-#{location.name}-#{private_subnet.ubid}"]}]}).security_groups[0]
    end

    private_subnet_aws_resource.update(security_group_id: security_group_response.group_id)

    private_subnet.firewalls(eager: :firewall_rules).flat_map(&:firewall_rules).each do |firewall_rule|
      next if firewall_rule.ip6?
      allow_ingress(security_group_response.group_id, firewall_rule.port_range.first, firewall_rule.port_range.last - 1, firewall_rule.cidr.to_s)
    end

    # Allow SSH ingress from the internet so that the controlplane can verify
    # that the VM is running.
    allow_ingress(security_group_response.group_id, 22, 22, "0.0.0.0/0")
    hop_create_route_table

  end

  label def create_route_table
    route_table_response = client.describe_route_tables({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]})
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet_aws_resource.update(route_table_id:)
    # Reuse only a gateway provably ours, found by the unique subnet tag or by an
    # existing attachment to our own vpc (recovery after a crashed attempt).
    # Reusing by the shared Name tag could adopt and attach a foreign subnet's
    # gateway, which destroy would then delete. Prefer one already attached to
    # our vpc so a duplicate tagged orphan from an earlier crashed attempt is
    # never attached on top of an already attached gateway.
    tagged = client.describe_internet_gateways({filters: [{name: "tag:SubnetUbid", values: [private_subnet.ubid]}]}).internet_gateways
    attached = client.describe_internet_gateways({filters: [{name: "attachment.vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).internet_gateways
    internet_gateway = attached.first || tagged.first

    if internet_gateway.nil?
      internet_gateway_id = client.create_internet_gateway({
        tag_specifications: Util.aws_tag_specifications("internet-gateway", private_subnet.name, {"SubnetUbid" => private_subnet.ubid}),
      }).internet_gateway.internet_gateway_id
      private_subnet_aws_resource.update(internet_gateway_id:)
      client.attach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet_aws_resource.vpc_id})
    else
      internet_gateway_id = internet_gateway.internet_gateway_id
      private_subnet_aws_resource.update(internet_gateway_id:)
      if internet_gateway.attachments.empty?
        client.attach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet_aws_resource.vpc_id})
      end
    end

    begin
      client.create_route({
        route_table_id:,
        destination_ipv_6_cidr_block: "::/0",
        gateway_id: internet_gateway_id,
      })

      client.create_route({
        route_table_id:,
        destination_cidr_block: "0.0.0.0/0",
        gateway_id: internet_gateway_id,
      })
    rescue Aws::EC2::Errors::RouteAlreadyExists
    end

    hop_create_az_subnets
  end

  label def create_az_subnets
    vpc = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).vpcs[0]
    vpc_ipv6 = NetAddr::IPv6Net.parse(vpc.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block)

    # AwsSubnet records were pre-created in SubnetNexus.assemble with IPv4 CIDRs
    # Now create the actual AWS subnets and update records with subnet_id and IPv6
    private_subnet_aws_resource.aws_subnets.each_with_index do |aws_subnet, idx|
      subnet = if aws_subnet.subnet_id
        client.describe_subnets({filters: [{name: "subnet-id", values: [aws_subnet.subnet_id]}]}).subnets[0]
      else
        az_name = location.name + aws_subnet.location_az.az
        ipv6_cidr = vpc_ipv6.nth_subnet(64, idx)

        begin
          client.create_subnet({
            vpc_id: private_subnet_aws_resource.vpc_id,
            cidr_block: aws_subnet.ipv4_cidr.to_s,
            ipv_6_cidr_block: ipv6_cidr.to_s,
            availability_zone: az_name,
            tag_specifications: Util.aws_tag_specifications("subnet", "#{private_subnet.name}-#{aws_subnet.location_az.az}"),
          }).subnet
        rescue Aws::EC2::Errors::InvalidSubnetConflict
          # Subnet was probably created in a previous attempt but database
          # wasn't updated. Find the existing subnet by AZ and CIDR.
          existing = client.describe_subnets({filters: [
            {name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]},
            {name: "availability-zone", values: [az_name]},
            {name: "cidr-block", values: [aws_subnet.ipv4_cidr.to_s]},
          ]}).subnets.first
          existing || fail("Subnet conflict but no matching subnet found for #{az_name}")
        end
      end

      aws_subnet.update(subnet_id: subnet.subnet_id, ipv6_cidr: subnet.ipv_6_cidr_block_association_set.first.ipv_6_cidr_block)
      client.modify_subnet_attribute({
        subnet_id: subnet.subnet_id,
        assign_ipv_6_address_on_creation: {value: true},
      })
    end

    hop_associate_az_route_tables
  end

  label def associate_az_route_tables
    private_subnet_aws_resource.aws_subnets.each do |aws_subnet|
      client.associate_route_table({
        route_table_id: private_subnet_aws_resource.route_table_id,
        subnet_id: aws_subnet.subnet_id,
      })
    rescue Aws::EC2::Errors::ResourceAlreadyAssociated
    end

    hop_create_guardduty_endpoint
  end

  label def create_guardduty_endpoint
    hop_wait unless private_subnet.project.get_ff_aws_cloudwatch_logs

    unless guardduty_endpoint
      client.create_vpc_endpoint({
        vpc_endpoint_type: "Interface",
        vpc_id: private_subnet_aws_resource.vpc_id,
        service_name: guardduty_service_name,
        subnet_ids: private_subnet_aws_resource.aws_subnets.map(&:subnet_id),
        security_group_ids: [private_subnet_aws_resource.security_group_id],
        private_dns_enabled: true,
        tag_specifications: Util.aws_tag_specifications("vpc-endpoint", private_subnet.name),
        client_token: private_subnet.id,
      })
    end

    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      private_subnet.vms.each(&:incr_update_firewall_rules)
      decr_update_firewall_rules
    end

    nap 60 * 60 * 24 * 365
  end

  label def destroy
    if private_subnet.nics.any? { |n| !n.vm_id.nil? }
      register_deadline(nil, 10 * 60, allow_extension: true) if private_subnet.nics.any? { |n| n.vm&.prevent_destroy_set? }

      Clog.emit("Cannot destroy subnet with active nics, first clean up the attached resources", private_subnet)

      nap 5
    end
    register_deadline(nil, 10 * 60)
    decr_destroy
    private_subnet.nics.each(&:incr_destroy)
    private_subnet.remove_all_firewalls

    hop_finish unless private_subnet_aws_resource
    hop_reconcile_vpc_orphans unless private_subnet_aws_resource.security_group_id

    if (endpoint = guardduty_endpoint)
      client.delete_vpc_endpoints({vpc_endpoint_ids: [endpoint.vpc_endpoint_id]})
    end

    begin
      ignore_invalid_id do
        client.delete_security_group({group_id: private_subnet_aws_resource.security_group_id})
      end
    rescue Aws::EC2::Errors::DependencyViolation => e
      if e.message.include?("resource #{private_subnet_aws_resource.security_group_id} has a dependent object")
        Clog.emit("Security group is in use", {security_group_in_use: {security_group_id: private_subnet_aws_resource.security_group_id}})
        nap 5
      end
      raise e
    end

    hop_delete_internet_gateway
  end

  label def reconcile_vpc_orphans
    # security_group_id was never persisted, so provisioning crashed before
    # wait_vpc_created committed. Rediscover the orphan vpc and security group
    # the way provisioning recovers them, then tear them down here so destroy
    # converges instead of wedging on a nil vpc_id or an untracked security
    # group. The vpc is rediscovered by the unique subnet tag, never the shared
    # Name, so a foreign subnet's vpc is never adopted and torn down. No internet
    # gateway, subnets, or guardduty endpoint exist this early, so none need
    # reconciling.
    vpc_id = private_subnet_aws_resource.vpc_id ||
      client.describe_vpcs({filters: [{name: "tag:SubnetUbid", values: [private_subnet.ubid]}]}).vpcs.first&.vpc_id

    unless vpc_id
      # Nothing visible yet. Give eventual consistency a bounded number of
      # tries before deciding the vpc was never created; only then is finishing
      # safe, since finishing destroys the db rows.
      tries = (reconcile_vpc_try || 0) + 1
      hop_finish if tries >= RECONCILE_VPC_MAX_TRIES
      self.reconcile_vpc_try = tries
      nap 10
    end

    self.reconcile_vpc_try = nil
    private_subnet_aws_resource.update(vpc_id:) unless private_subnet_aws_resource.vpc_id

    client.describe_security_groups({filters: [
      {name: "vpc-id", values: [vpc_id]},
      {name: "group-name", values: ["aws-#{location.name}-#{private_subnet.ubid}"]},
    ]}).security_groups.each do |security_group|
      ignore_invalid_id do
        client.delete_security_group({group_id: security_group.group_id})
      end
    end

    begin
      client.delete_vpc({vpc_id:})
    rescue Aws::EC2::Errors::DependencyViolation
      # An orphan security group may not have been visible to the describe
      # above yet; nap and re-reconcile so it is deleted before the vpc.
      nap 10
    rescue Aws::EC2::Errors::InvalidVpcIDNotFound
    end

    hop_finish
  end

  label def delete_internet_gateway
    # Reap only gateways provably ours: the orphan by its unique SubnetUbid tag
    # (created before its id was persisted, so still unattached) and the
    # attached gateway by its attachment to our own vpc. Both keys are unique to
    # this subnet. The Name tag and the persisted id are deliberately not used:
    # subnet names are unique only per project but the AWS account is shared,
    # and the create path can adopt a foreign gateway into our persisted id by
    # Name, so either could point at another subnet's gateway.
    internet_gateway_ids = client.describe_internet_gateways({filters: [{name: "tag:SubnetUbid", values: [private_subnet.ubid]}]}).internet_gateways.map(&:internet_gateway_id)
    internet_gateway_ids += client.describe_internet_gateways({filters: [{name: "attachment.vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).internet_gateways.map(&:internet_gateway_id)
    internet_gateway_ids.compact.uniq.each do |internet_gateway_id|
      ignore_invalid_id do
        client.detach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet_aws_resource.vpc_id})
      end
      ignore_invalid_id do
        client.delete_internet_gateway({internet_gateway_id:})
      end
    end
    hop_delete_az_subnets
  end

  label def delete_az_subnets
    # Delete every subnet in the vpc, found by describe rather than the
    # persisted ids, so an orphan created before its id was persisted (nil in
    # the db) is reaped too instead of wedging delete_vpc. The outer
    # ignore_invalid_id tolerates a vpc already gone or a nil vpc_id.
    ignore_invalid_id do
      client.describe_subnets({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).subnets.each do |subnet|
        ignore_invalid_id do
          client.delete_subnet({subnet_id: subnet.subnet_id})
        end
      end
    end

    # AwsSubnet DB records are cleaned up via CASCADE when
    # private_subnet_aws_resource is destroyed in #finish
    hop_delete_vpc
  end

  label def delete_vpc
    begin
      client.delete_vpc({vpc_id: private_subnet_aws_resource.vpc_id})
    rescue Aws::EC2::Errors::DependencyViolation => e
      Clog.emit("VPC has dependencies, retrying subnet cleanup", {vpc_dependency: {vpc_id: private_subnet_aws_resource.vpc_id, error: e.message}})
      raise e
    rescue Aws::EC2::Errors::InvalidVpcIDNotFound
      # VPC already deleted
    end
    hop_finish
  end

  label def finish
    nap 5 unless private_subnet.nics.empty?
    private_subnet_aws_resource&.destroy
    private_subnet.destroy
    pop "vpc destroyed"
  end

  def ignore_invalid_id
    yield
  rescue ArgumentError,
    Aws::EC2::Errors::GatewayNotAttached,
    Aws::EC2::Errors::InvalidSubnetIDNotFound,
    Aws::EC2::Errors::InvalidGroupNotFound,
    Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidInternetGatewayIDNotFound,
    Aws::EC2::Errors::InvalidVpcIDNotFound => e
    Clog.emit("ID not found for aws vpc", {ignored_aws_vpc_failure: Util.exception_to_hash(e, backtrace: nil)})
  end

  def location
    @location ||= private_subnet.location
  end

  def client
    @client ||= location.location_credential_aws.client
  end

  def allow_ingress(group_id, from_port, to_port, cidr)
    client.authorize_security_group_ingress({
      group_id:,
      ip_permissions: [{
        ip_protocol: "tcp",
        from_port:,
        to_port:,
        ip_ranges: [{cidr_ip: cidr}],
      }],
    })
  rescue Aws::EC2::Errors::InvalidPermissionDuplicate
  end

  def private_subnet_aws_resource
    @private_subnet_aws_resource ||= private_subnet.private_subnet_aws_resource
  end

  def guardduty_service_name
    "com.amazonaws.#{location.name}.guardduty-data"
  end

  def guardduty_endpoint
    client.describe_vpc_endpoints({filters: [
      {name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]},
      {name: "service-name", values: [guardduty_service_name]},
    ]}).vpc_endpoints.first
  end
end
