# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Aws::Vpc < Prog::Base
  subject_is :private_subnet

  label def create_vpc
    vpc_response = client.describe_vpcs({filters: [{name: "tag:Name", values: [private_subnet.name]}]})

    vpc_id = if vpc_response.vpcs.empty?
      client.create_vpc({cidr_block: private_subnet.net4.to_s,
        amazon_provided_ipv_6_cidr_block: true,
        tag_specifications: Util.aws_tag_specifications("vpc", private_subnet.name)}).vpc.vpc_id
    else
      vpc_response.vpcs.first.vpc_id
    end

    private_subnet.private_subnet_aws_resource.update(vpc_id: vpc_id)
    hop_wait_vpc_created
  end

  label def wait_vpc_created
    vpc = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]}).vpcs[0]

    if vpc.state == "available"
      security_group_response = begin
        client.create_security_group({
          group_name: "aws-#{location.name}-#{private_subnet.ubid}",
          description: "Security group for aws-#{location.name}-#{private_subnet.ubid}",
          vpc_id: private_subnet.private_subnet_aws_resource.vpc_id,
          tag_specifications: Util.aws_tag_specifications("security-group", private_subnet.name)
        })
      rescue Aws::EC2::Errors::InvalidGroupDuplicate
        client.describe_security_groups({filters: [{name: "group-name", values: ["aws-#{location.name}-#{private_subnet.ubid}"]}]}).security_groups[0]
      end

      private_subnet.private_subnet_aws_resource.update(security_group_id: security_group_response.group_id)

      private_subnet.firewalls.flat_map(&:firewall_rules).each do |firewall_rule|
        next if firewall_rule.ip6?
        begin
          client.authorize_security_group_ingress({
            group_id: security_group_response.group_id,
            ip_permissions: [{
              ip_protocol: "tcp",
              from_port: firewall_rule.port_range.first,
              to_port: firewall_rule.port_range.last - 1,
              ip_ranges: [{cidr_ip: firewall_rule.cidr.to_s}]
            }]
          })
        rescue Aws::EC2::Errors::InvalidPermissionDuplicate
        end
      end
      hop_create_subnet
    end
    nap 1
  end

  label def create_subnet
    vpc_response = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]}).vpcs[0]
    ipv_6_cidr_block = vpc_response.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block.gsub("/56", "")
    subnet_response = client.create_subnet({
      vpc_id: vpc_response.vpc_id,
      cidr_block: private_subnet.net4.to_s,
      ipv_6_cidr_block: "#{ipv_6_cidr_block}/64",
      availability_zone: location.name + "a", # YYY: This is a hack since we don't support multiple AZs yet
      tag_specifications: Util.aws_tag_specifications("subnet", private_subnet.name)
    })

    subnet_id = subnet_response.subnet.subnet_id
    # Enable auto-assign ipv_6 addresses for the subnet
    client.modify_subnet_attribute({
      subnet_id: subnet_id,
      assign_ipv_6_address_on_creation: {value: true}
    })

    private_subnet.private_subnet_aws_resource.update(subnet_id: subnet_id)
    hop_wait_subnet_created
  end

  label def wait_subnet_created
    subnet_response = client.describe_subnets({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]}).subnets[0]

    if subnet_response.state == "available"
      hop_create_route_table
    end
    nap 1
  end

  label def create_route_table
    # Step 3: Update the route table for ipv_6 traffic
    route_table_response = client.describe_route_tables({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]})
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet.private_subnet_aws_resource.update(route_table_id: route_table_id)
    internet_gateway_response = client.create_internet_gateway({
      tag_specifications: Util.aws_tag_specifications("internet-gateway", private_subnet.name)
    })
    internet_gateway_id = internet_gateway_response.internet_gateway.internet_gateway_id
    private_subnet.private_subnet_aws_resource.update(internet_gateway_id: internet_gateway_id)
    client.attach_internet_gateway({internet_gateway_id: internet_gateway_id, vpc_id: private_subnet.private_subnet_aws_resource.vpc_id})

    begin
      client.create_route({
        route_table_id: route_table_id,
        destination_ipv_6_cidr_block: "::/0",
        gateway_id: internet_gateway_id
      })

      client.create_route({
        route_table_id: route_table_id,
        destination_cidr_block: "0.0.0.0/0",
        gateway_id: internet_gateway_id
      })
    rescue Aws::EC2::Errors::RouteAlreadyExists
    end

    client.associate_route_table({
      route_table_id: route_table_id,
      subnet_id: private_subnet.private_subnet_aws_resource.subnet_id
    })

    pop "subnet created"
  end

  label def destroy
    subnet = client.describe_subnets({filters: [{name: "subnet-id", values: [private_subnet.private_subnet_aws_resource.subnet_id]}]}).subnets.first
    hop_delete_security_group unless subnet

    nap 5 if subnet.state != "available"
    begin
      client.delete_subnet({subnet_id: private_subnet.private_subnet_aws_resource.subnet_id})
    rescue Aws::EC2::Errors::DependencyViolation
      nap 5
    end
    hop_delete_security_group
  end

  label def delete_security_group
    ignore_invalid_id do
      client.delete_security_group({group_id: private_subnet.private_subnet_aws_resource.security_group_id})
    end
    hop_delete_internet_gateway
  end

  label def delete_internet_gateway
    ignore_invalid_id do
      client.detach_internet_gateway({internet_gateway_id: private_subnet.private_subnet_aws_resource.internet_gateway_id, vpc_id: private_subnet.private_subnet_aws_resource.vpc_id})
      client.delete_internet_gateway({internet_gateway_id: private_subnet.private_subnet_aws_resource.internet_gateway_id})
    end
    hop_delete_vpc
  end

  label def delete_vpc
    ignore_invalid_id do
      client.delete_vpc({vpc_id: private_subnet.private_subnet_aws_resource.vpc_id})
    end
    pop "vpc destroyed"
  end

  def ignore_invalid_id
    yield
  rescue Aws::EC2::Errors::InvalidSubnetIDNotFound,
    Aws::EC2::Errors::InvalidGroupNotFound,
    Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidInternetGatewayIDNotFound,
    Aws::EC2::Errors::InvalidVpcIDNotFound => e
    Clog.emit("ID not found") { {exception: {error_code: e.code, error_message: e.message}} }
  end

  def location
    private_subnet.location
  end

  def client
    @client ||= location.location_credential.client
  end
end
