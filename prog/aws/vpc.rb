# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Aws::Vpc < Prog::Base
  subject_is :private_subnet

  def before_run
    when_destroy_set? do
      pop "exiting early due to destroy semaphore"
    end
  end

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
      client.modify_vpc_attribute({
        vpc_id: vpc.vpc_id,
        enable_dns_hostnames: {value: true}
      })

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
      hop_create_route_table
    end
    nap 1
  end

  label def create_route_table
    # Step 3: Update the route table for ipv_6 traffic
    route_table_response = client.describe_route_tables({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]})
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet.private_subnet_aws_resource.update(route_table_id: route_table_id)
    internet_gateway_response = client.describe_internet_gateways({filters: [{name: "tag:Name", values: [private_subnet.name]}]})

    if internet_gateway_response.internet_gateways.empty?
      internet_gateway_id = client.create_internet_gateway({
        tag_specifications: Util.aws_tag_specifications("internet-gateway", private_subnet.name)
      }).internet_gateway.internet_gateway_id
      private_subnet.private_subnet_aws_resource.update(internet_gateway_id:)
      client.attach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet.private_subnet_aws_resource.vpc_id})
    else
      internet_gateway = internet_gateway_response.internet_gateways.first
      internet_gateway_id = internet_gateway.internet_gateway_id
      private_subnet.private_subnet_aws_resource.update(internet_gateway_id:)
      if internet_gateway.attachments.empty?
        client.attach_internet_gateway({internet_gateway_id:, vpc_id: private_subnet.private_subnet_aws_resource.vpc_id})
      end
    end

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

    pop "subnet created"
  end

  label def destroy
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
  rescue ArgumentError,
    Aws::EC2::Errors::GatewayNotAttached,
    Aws::EC2::Errors::InvalidSubnetIDNotFound,
    Aws::EC2::Errors::InvalidGroupNotFound,
    Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidInternetGatewayIDNotFound,
    Aws::EC2::Errors::InvalidVpcIDNotFound => e
    Clog.emit("ID not found for aws vpc") { {ignored_aws_vpc_failure: {exception: Util.exception_to_hash(e, backtrace: nil)}} }
  end

  def location
    private_subnet.location
  end

  def client
    @client ||= location.location_credential.client
  end
end
