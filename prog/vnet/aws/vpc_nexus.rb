# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Vnet::Aws::VpcNexus < Prog::Base
  subject_is :private_subnet

  label def start
    # PrivateSubnetAwsResource and AwsSubnet records are created in SubnetNexus.assemble
    vpc_response = client.describe_vpcs({filters: [{name: "tag:Name", values: [private_subnet.name]}]})

    vpc_id = if vpc_response.vpcs.empty?
      client.create_vpc({cidr_block: private_subnet.net4.to_s,
        amazon_provided_ipv_6_cidr_block: true,
        tag_specifications: Util.aws_tag_specifications("vpc", private_subnet.name)}).vpc.vpc_id
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
      enable_dns_hostnames: {value: true}
    })

    security_group_response = begin
      client.create_security_group({
        group_name: "aws-#{location.name}-#{private_subnet.ubid}",
        description: "Security group for aws-#{location.name}-#{private_subnet.ubid}",
        vpc_id: private_subnet_aws_resource.vpc_id,
        tag_specifications: Util.aws_tag_specifications("security-group", private_subnet.name)
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
    internet_gateway_response = client.describe_internet_gateways({filters: [{name: "tag:Name", values: [private_subnet.name]}]})

    if internet_gateway_response.internet_gateways.empty?
      internet_gateway_id = client.create_internet_gateway({
        tag_specifications: Util.aws_tag_specifications("internet-gateway", private_subnet.name)
      }).internet_gateway.internet_gateway_id
      private_subnet_aws_resource.update(internet_gateway_id:)
      client.attach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet_aws_resource.vpc_id})
    else
      internet_gateway = internet_gateway_response.internet_gateways.first
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
        gateway_id: internet_gateway_id
      })

      client.create_route({
        route_table_id:,
        destination_cidr_block: "0.0.0.0/0",
        gateway_id: internet_gateway_id
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
        ipv6_cidr = vpc_ipv6.nth_subnet(64, idx)

        client.create_subnet({
          vpc_id: private_subnet_aws_resource.vpc_id,
          cidr_block: aws_subnet.ipv4_cidr.to_s,
          ipv_6_cidr_block: ipv6_cidr.to_s,
          availability_zone: location.name + aws_subnet.location_aws_az.az,
          tag_specifications: Util.aws_tag_specifications("subnet", "#{private_subnet.name}-#{aws_subnet.location_aws_az.az}")
        }).subnet
      end

      aws_subnet.update(subnet_id: subnet.subnet_id, ipv6_cidr: subnet.ipv_6_cidr_block_association_set.first.ipv_6_cidr_block)
      client.modify_subnet_attribute({
        subnet_id: subnet.subnet_id,
        assign_ipv_6_address_on_creation: {value: true}
      })
    end

    hop_associate_az_route_tables
  end

  label def associate_az_route_tables
    private_subnet_aws_resource.aws_subnets.each do |aws_subnet|
      client.associate_route_table({
        route_table_id: private_subnet_aws_resource.route_table_id,
        subnet_id: aws_subnet.subnet_id
      })
    rescue Aws::EC2::Errors::ResourceAlreadyAssociated
    end

    hop_wait
  end

  label def wait
    when_refresh_keys_set? do
      # AWS has no IPsec tunnels — nothing to rekey, just clear the semaphore
      decr_refresh_keys
    end

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

  label def delete_internet_gateway
    ignore_invalid_id do
      client.detach_internet_gateway({internet_gateway_id: private_subnet_aws_resource.internet_gateway_id, vpc_id: private_subnet_aws_resource.vpc_id})
    end

    ignore_invalid_id do
      client.delete_internet_gateway({internet_gateway_id: private_subnet_aws_resource.internet_gateway_id})
    end
    hop_delete_az_subnets
  end

  label def delete_az_subnets
    # Delete AWS subnets tracked in our database
    private_subnet_aws_resource.aws_subnets.each do |aws_subnet|
      ignore_invalid_id do
        client.delete_subnet({subnet_id: aws_subnet.subnet_id})
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
    @client ||= location.location_credential.client
  end

  def allow_ingress(group_id, from_port, to_port, cidr)
    client.authorize_security_group_ingress({
      group_id:,
      ip_permissions: [{
        ip_protocol: "tcp",
        from_port:,
        to_port:,
        ip_ranges: [{cidr_ip: cidr}]
      }]
    })
  rescue Aws::EC2::Errors::InvalidPermissionDuplicate
  end

  def private_subnet_aws_resource
    @private_subnet_aws_resource ||= private_subnet.private_subnet_aws_resource
  end
end
