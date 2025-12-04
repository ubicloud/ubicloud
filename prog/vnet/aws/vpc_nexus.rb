# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Vnet::Aws::VpcNexus < Prog::Base
  subject_is :private_subnet

  def before_run
    when_destroy_set? do
      when_destroying_set? { return }
      register_deadline(nil, 10 * 60)
      hop_destroy
    end
  end

  label def start
    PrivateSubnetAwsResource.create_with_id(private_subnet.id)
    hop_create_vpc
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

    private_subnet_aws_resource.update(vpc_id: vpc_id)
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
    # Step 3: Update the route table for ipv_6 traffic
    route_table_response = client.describe_route_tables({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]})
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet_aws_resource.update(route_table_id: route_table_id)
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

      Clog.emit("Cannot destroy subnet with active nics, first clean up the attached resources") { private_subnet }

      nap 5
    end

    decr_destroy
    private_subnet.nics.each(&:incr_destroy)
    private_subnet.remove_all_firewalls
    Semaphore.incr(strand.children_dataset.where(prog: "Aws::Vpc").select(:id), "destroy")

    ignore_invalid_id do
      client.delete_security_group({group_id: private_subnet_aws_resource.security_group_id})
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
    hop_delete_vpc
  end

  label def delete_vpc
    ignore_invalid_id do
      client.delete_vpc({vpc_id: private_subnet_aws_resource.vpc_id})
    end

    nap 5 unless private_subnet.nics.empty?
    private_subnet_aws_resource.destroy
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
    Clog.emit("ID not found for aws vpc") { {ignored_aws_vpc_failure: {exception: Util.exception_to_hash(e, backtrace: nil)}} }
  end

  def location
    @location ||= private_subnet.location
  end

  def client
    @client ||= location.location_credential.client
  end

  def allow_ingress(group_id, from_port, to_port, cidr)
    client.authorize_security_group_ingress({
      group_id: group_id,
      ip_permissions: [{
        ip_protocol: "tcp",
        from_port: from_port,
        to_port: to_port,
        ip_ranges: [{cidr_ip: cidr}]
      }]
    })
  rescue Aws::EC2::Errors::InvalidPermissionDuplicate
  end

  def private_subnet_aws_resource
    @private_subnet_aws_resource ||= private_subnet.private_subnet_aws_resource
  end
end
