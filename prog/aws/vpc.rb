# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Aws::Vpc < Prog::Base
  subject_is :private_subnet

  label def create_vpc
    vpc_response = client.create_vpc({cidr_block: private_subnet.net4.to_s,
      amazon_provided_ipv_6_cidr_block: true,
      tag_specifications: tag_specifications("vpc")})
    private_subnet.update(name: vpc_response.vpc.vpc_id)
    private_subnet.private_subnet_aws_resource.update(vpc_id: vpc_response.vpc.vpc_id)
    hop_wait_vpc_created
  end

  label def wait_vpc_created
    vpc = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet.name]}]}).vpcs[0]

    if vpc.state == "available"
      security_group_response = begin
        client.create_security_group({
          group_name: "aws-#{location.name}-#{private_subnet.ubid}",
          description: "Security group for aws-#{location.name}-#{private_subnet.ubid}",
          vpc_id: private_subnet.name,
          tag_specifications: tag_specifications("security-group")
        })
      rescue Aws::EC2::Errors::InvalidGroupDuplicate
        client.describe_security_groups({filters: [{name: "group-name", values: ["aws-#{location.name}-#{private_subnet.ubid}"]}]}).security_groups[0]
      end

      private_subnet.private_subnet_aws_resource.update(security_group_id: security_group_response.group_id)

      private_subnet.firewalls.flat_map(&:firewall_rules).each do |firewall_rule|
        next if firewall_rule.ip6?
        client.authorize_security_group_ingress({
          group_id: security_group_response.group_id,
          ip_permissions: [{
            ip_protocol: "tcp",
            from_port: firewall_rule.port_range.first,
            to_port: firewall_rule.port_range.last - 1,
            ip_ranges: [{cidr_ip: firewall_rule.cidr.to_s}]
          }]
        })
      end
      hop_create_subnet
    end
    nap 1
  end

  label def create_subnet
    vpc_response = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet.name]}]}).vpcs[0]
    ipv_6_cidr_block = vpc_response.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block.gsub("/56", "")
    subnet_response = client.create_subnet({
      vpc_id: vpc_response.vpc_id,
      cidr_block: private_subnet.net4.to_s,
      ipv_6_cidr_block: "#{ipv_6_cidr_block}/64",
      availability_zone: location.name + "a", # YYY: This is a hack since we don't support multiple AZs yet
      tag_specifications: tag_specifications("subnet")
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
    subnet_response = client.describe_subnets({filters: [{name: "vpc-id", values: [private_subnet.name]}]}).subnets[0]

    if subnet_response.state == "available"
      hop_create_route_table
    end
    nap 1
  end

  label def create_route_table
    # Step 3: Update the route table for ipv_6 traffic
    route_table_response = client.describe_route_tables({
      filters: [{name: "vpc-id", values: [private_subnet.name]}]
    })
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet.private_subnet_aws_resource.update(route_table_id: route_table_id)
    internet_gateway_response = client.create_internet_gateway({
      tag_specifications: tag_specifications("internet-gateway")
    })
    internet_gateway_id = internet_gateway_response.internet_gateway.internet_gateway_id
    private_subnet.private_subnet_aws_resource.update(internet_gateway_id: internet_gateway_id)
    client.attach_internet_gateway({
      internet_gateway_id: internet_gateway_id,
      vpc_id: private_subnet.name
    })

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
    client.delete_subnet({subnet_id: private_subnet.private_subnet_aws_resource.subnet_id})
    hop_delete_security_group
  rescue Aws::EC2::Errors::InvalidSubnetIDNotFound
    hop_delete_security_group
  end

  label def delete_security_group
    client.delete_security_group({group_id: private_subnet.private_subnet_aws_resource.security_group_id})
    hop_delete_internet_gateway
  rescue Aws::EC2::Errors::InvalidGroupNotFound
    hop_delete_internet_gateway
  end

  label def delete_internet_gateway
    client.detach_internet_gateway({internet_gateway_id: private_subnet.private_subnet_aws_resource.internet_gateway_id, vpc_id: private_subnet.name})
    client.delete_internet_gateway({internet_gateway_id: private_subnet.private_subnet_aws_resource.internet_gateway_id})
    hop_delete_vpc
  rescue Aws::EC2::Errors::InvalidInternetGatewayIDNotFound
    hop_delete_vpc
  end

  label def delete_vpc
    client.delete_vpc({vpc_id: private_subnet.name})
    pop "vpc destroyed"
  rescue Aws::EC2::Errors::InvalidVpcIDNotFound
    pop "vpc destroyed"
  end

  def location
    private_subnet.location
  end

  def client
    @client ||= location.location_credential.client
  end

  def tag_specifications(resource_type)
    [
      {
        resource_type: resource_type,
        tags: [
          {key: "Ubicloud", value: "true"}
        ]
      }
    ]
  end
end
