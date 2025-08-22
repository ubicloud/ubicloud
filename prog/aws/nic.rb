# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Aws::Nic < Prog::Base
  subject_is :nic

  label def create_subnet
    register_deadline("attach_eip_network_interface", 3 * 60)
    vpc_response = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]}).vpcs[0]
    ipv_6_cidr_block = NetAddr::IPv6Net.parse(vpc_response.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block).nth_subnet(64, SecureRandom.random_number(2**8))
    subnet_response = client.describe_subnets({filters: [{name: "tag:Name", values: [nic.name]}]})
    subnet_id = if private_subnet.old_aws_subnet?
      client.describe_subnets({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]}).subnets[0].subnet_id
    elsif subnet_response.subnets.empty?
      subnet_id = client.create_subnet({
        vpc_id: private_subnet.private_subnet_aws_resource.vpc_id,
        cidr_block: NetAddr::IPv4Net.new(nic.private_ipv4.network, NetAddr::Mask32.new(24)).to_s,
        ipv_6_cidr_block: ipv_6_cidr_block.to_s,
        availability_zone: private_subnet.location.name + az_to_provision_subnet,
        tag_specifications: Util.aws_tag_specifications("subnet", nic.name)
      }).subnet.subnet_id
      client.modify_subnet_attribute({
        subnet_id:,
        assign_ipv_6_address_on_creation: {value: true}
      })
      subnet_id
    else
      subnet_response.subnets[0].subnet_id
    end
    nic.nic_aws_resource.update(subnet_id:, subnet_az: az_to_provision_subnet)

    hop_wait_subnet_created
  end

  label def wait_subnet_created
    subnet_response = if private_subnet.old_aws_subnet?
      hop_create_network_interface
    else
      client.describe_subnets({filters: [{name: "tag:Name", values: [nic.name]}]}).subnets[0]
    end

    if subnet_response.state == "available"
      route_table_response = client.describe_route_tables({filters: [{name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]}]})
      route_table_id = route_table_response.route_tables[0].route_table_id
      route_table_details = client.describe_route_tables({route_table_ids: [route_table_id]}).route_tables.first
      if route_table_details.associations.empty?
        client.associate_route_table({
          route_table_id:,
          subnet_id: nic.nic_aws_resource.subnet_id
        })
      end
      hop_create_network_interface
    end
    nap 1
  end

  label def create_network_interface
    network_interface_response = client.create_network_interface({
      subnet_id: nic.nic_aws_resource.subnet_id,
      private_ip_address: nic.private_ipv4.network.to_s,
      ipv_6_prefix_count: 1,
      groups: [
        nic.private_subnet.private_subnet_aws_resource.security_group_id
      ],
      tag_specifications: Util.aws_tag_specifications("network-interface", nic.name),
      client_token: nic.id
    })
    network_interface_id = network_interface_response.network_interface.network_interface_id
    nic.nic_aws_resource.update(network_interface_id:)

    hop_assign_ipv6_address
  end

  label def assign_ipv6_address
    client.assign_ipv_6_addresses({network_interface_id: nic.nic_aws_resource.network_interface_id, ipv_6_address_count: 1}) if get_network_interface.ipv_6_addresses.empty?
    hop_wait_network_interface_created
  end

  label def wait_network_interface_created
    if get_network_interface.status == "available"
      hop_allocate_eip
    end

    nap 1
  end

  label def allocate_eip
    eip_response = client.describe_addresses({filters: [{name: "tag:Name", values: [nic.name]}]})
    eip_allocation_id = if eip_response.addresses.empty?
      client.allocate_address(tag_specifications: Util.aws_tag_specifications("elastic-ip", nic.nic_aws_resource.network_interface_id)).allocation_id
    else
      eip_response.addresses[0].allocation_id
    end

    nic.nic_aws_resource.update(eip_allocation_id:)
    hop_attach_eip_network_interface
  end

  label def attach_eip_network_interface
    eip_response = client.describe_addresses({filters: [{name: "allocation-id", values: [nic.nic_aws_resource.eip_allocation_id]}]})
    if eip_response.addresses.first.network_interface_id.nil?
      client.associate_address({allocation_id: nic.nic_aws_resource.eip_allocation_id, network_interface_id: nic.nic_aws_resource.network_interface_id})
    end
    pop "nic created"
  end

  label def destroy
    ignore_invalid_nic do
      client.delete_network_interface({network_interface_id: nic.nic_aws_resource.network_interface_id})
    end
    hop_release_eip
  end

  label def release_eip
    ignore_invalid_nic do
      allocation_id = nic.nic_aws_resource&.eip_allocation_id
      client.release_address({allocation_id: allocation_id}) if allocation_id
    end
    hop_delete_subnet
  end

  label def delete_subnet
    ignore_invalid_nic do
      client.delete_subnet({subnet_id: nic.nic_aws_resource.subnet_id})
    rescue Aws::EC2::Errors::DependencyViolation => e
      raise e if private_subnet.nics.count == 1
      Clog.emit("DependencyViolation") { Util.exception_to_hash(e) }
    end
    pop "nic destroyed"
  end

  def client
    @client ||= nic.private_subnet.location.location_credential.client
  end

  def private_subnet
    @private_subnet ||= nic.private_subnet
  end

  def az_to_provision_subnet
    frame["availability_zone"] || (["a", "b", "c"] - (frame["exclude_availability_zones"] || [])).sample || "a"
  end

  def get_network_interface
    client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic.nic_aws_resource.network_interface_id]}, {name: "tag:Ubicloud", values: ["true"]}]}).network_interfaces[0]
  end

  private

  def ignore_invalid_nic
    yield
  rescue ArgumentError,
    Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidAllocationIDNotFound,
    Aws::EC2::Errors::InvalidAddressIDNotFound,
    Aws::EC2::Errors::InvalidSubnetIDNotFound => e
    Clog.emit("ID not found") { Util.exception_to_hash(e) }
  end
end
