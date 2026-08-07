# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::Vnet::Aws::NicNexus < Prog::Base
  subject_is :nic
  frame_reader :aws_subnet_id, :use_eip, :use_per_nic_security_group

  label def start
    register_deadline("wait", 5 * 60)
    NicAwsResource.create_with_id(nic.id, use_eip: use_eip != false)
    hop_create_subnet
  end

  label def create_subnet
    nap 2 unless private_subnet.strand.label == "wait"

    # AwsSubnet was selected at assemble time and stored in frame
    aws_subnet = nic.private_subnet.private_subnet_aws_resource.aws_subnets_dataset.first(id: aws_subnet_id)
    fail "No available AWS subnet found" unless aws_subnet

    nic.nic_aws_resource.update(
      subnet_id: aws_subnet.subnet_id,
      subnet_az: aws_subnet.az_suffix,
      aws_subnet_id: aws_subnet.id,
    )

    hop_create_security_group if use_per_nic_security_group
    hop_wait unless nic.nic_aws_resource.use_eip

    register_deadline("attach_eip_network_interface", 3 * 60)
    hop_create_network_interface
  end

  label def create_security_group
    ps_aws = private_subnet.private_subnet_aws_resource
    group_name = "aws-#{private_subnet.location.name}-#{nic.ubid}-user"
    security_group_id = nic.nic_aws_resource.security_group_id
    if security_group_id
      begin
        security_group_id = nil if client.describe_security_groups(group_ids: [security_group_id]).security_groups.empty?
      rescue Aws::EC2::Errors::InvalidGroupNotFound
        security_group_id = nil
      end
      nic.nic_aws_resource.update(security_group_id: nil) unless security_group_id
    end

    security_group_id ||= begin
      client.create_security_group({
        group_name:,
        description: "User security group for aws-#{private_subnet.location.name}-#{nic.ubid}",
        vpc_id: ps_aws.vpc_id,
        tag_specifications: Util.aws_tag_specifications("security-group", nic.name, ownership_tags),
      }).group_id
    rescue Aws::EC2::Errors::InvalidGroupDuplicate
      client.describe_security_groups({filters: [{name: "vpc-id", values: [ps_aws.vpc_id]}, {name: "group-name", values: [group_name]}]}).security_groups[0].group_id
    end
    nic.nic_aws_resource.update(security_group_id:)
    Config.control_plane_outbound_cidrs.each { allow_ingress(security_group_id, it) }

    hop_wait unless nic.nic_aws_resource.use_eip

    register_deadline("attach_eip_network_interface", 3 * 60)
    hop_create_network_interface
  end

  label def create_network_interface
    begin
      ps_aws = private_subnet.private_subnet_aws_resource
      sg_id = nic.nic_aws_resource.security_group_id || (nic.is_management ? ps_aws.mgmt_security_group_id : ps_aws.user_security_group_id)
      network_interface_response = client.create_network_interface({
        subnet_id: nic.nic_aws_resource.subnet_id,
        private_ip_address: nic.private_ipv4.network.to_s,
        ipv_6_prefix_count: 1,
        groups: [sg_id],
        tag_specifications: Util.aws_tag_specifications("network-interface", nic.name),
        client_token: nic.id,
      })
      network_interface_id = network_interface_response.network_interface.network_interface_id
    rescue Aws::EC2::Errors::InvalidIPAddressInUse
      network_interfaces = client.describe_network_interfaces({
        filters: [
          {name: "subnet-id", values: [nic.nic_aws_resource.subnet_id]},
          {name: "addresses.private-ip-address", values: [nic.private_ipv4.network.to_s]},
          {name: "status", values: ["available"]},
        ],
      }).network_interfaces
      fail "No available network interface found for IP #{nic.private_ipv4.network}" if network_interfaces.empty?
      network_interface_id = network_interfaces[0].network_interface_id
    end
    nic.nic_aws_resource.update(network_interface_id:)

    # AWS by default rejects outgoing traffic if response is coming out of network interface
    # that is different from the one that received the request. When multiple network interfaces
    # are attached, we either need to disable source/dest check or add routing rules to ensure
    # response goes out of the same network interface. Disabling source/dest check is simpler and
    # safe because of our single-tenancy model.
    client.modify_network_interface_attribute(
      network_interface_id:,
      source_dest_check: {value: false},
    )

    hop_assign_ipv6_address
  end

  label def assign_ipv6_address
    nap 1 unless (network_interface = get_network_interface)
    if network_interface.ipv_6_addresses.empty?
      client.assign_ipv_6_addresses({network_interface_id: nic.nic_aws_resource.network_interface_id, ipv_6_address_count: 1})
    end
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
    nap(1) unless (address = eip_response.addresses.first)
    unless address.network_interface_id
      client.associate_address({allocation_id: nic.nic_aws_resource.eip_allocation_id, network_interface_id: nic.nic_aws_resource.network_interface_id})
    end
    hop_wait
  end

  label def wait
    nap 1000000000
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    hop_destroy_entities unless nic.nic_aws_resource

    hop_wait_network_interface_deleted unless nic.nic_aws_resource.use_eip

    begin
      ignore_invalid_nic do
        client.delete_network_interface({network_interface_id: nic.nic_aws_resource.network_interface_id})
      end
    rescue Aws::EC2::Errors::InvalidParameterValue => e
      if e.message.include?("Network interface '#{nic.nic_aws_resource.network_interface_id}' is currently in use.")
        Clog.emit("Network interface is in use", {network_interface_in_use: {network_interface_id: nic.nic_aws_resource.network_interface_id}})
        nap 5
      end
      raise e
    end
    hop_release_eip
  end

  label def wait_network_interface_deleted
    network_interface_id = nic.nic_aws_resource.network_interface_id
    hop_release_eip unless network_interface_id

    begin
      network_interface = client.describe_network_interfaces(network_interface_ids: [network_interface_id]).network_interfaces.first
    rescue Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound
      hop_release_eip
    end
    hop_release_eip unless network_interface

    if network_interface.status == "available"
      begin
        client.delete_network_interface(network_interface_id:)
      rescue Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound
        hop_release_eip
      end
    end
    nap 5
  end

  label def release_eip
    ignore_invalid_nic do
      allocation_id = nic.nic_aws_resource&.eip_allocation_id
      client.release_address({allocation_id:}) if allocation_id
    end
    hop_delete_security_group
  end

  label def delete_security_group
    if (security_group_id = nic.nic_aws_resource&.security_group_id)
      begin
        client.delete_security_group({group_id: security_group_id})
      rescue Aws::EC2::Errors::DependencyViolation => e
        Clog.emit("Security group is in use", {security_group_in_use: {security_group_id:, error: e.message}})
        nap 5
      rescue Aws::EC2::Errors::InvalidGroupNotFound
        nil
      end
    end
    hop_destroy_entities
  end

  label def destroy_entities
    nic&.nic_aws_resource&.destroy
    nic&.destroy
    pop "nic deleted"
  end

  def client
    @client ||= private_subnet.location.location_credential_aws.client
  end

  def private_subnet
    @private_subnet ||= nic.private_subnet
  end

  def get_network_interface
    client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic.nic_aws_resource.network_interface_id]}, {name: "tag:Ubicloud", values: [Config.provider_resource_tag_value]}]}).network_interfaces[0]
  end

  def allow_ingress(group_id, cidr)
    ranges = cidr.include?(":") ? {ipv_6_ranges: [{cidr_ipv_6: cidr}]} : {ip_ranges: [{cidr_ip: cidr}]}
    client.authorize_security_group_ingress({
      group_id:,
      ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, **ranges}],
    })
  rescue Aws::EC2::Errors::InvalidPermissionDuplicate
    nil
  end

  def ownership_tags
    tags = {"PrivateSubnet" => private_subnet.ubid, "Nic" => nic.ubid}
    if (installation = private_subnet.github_installation)
      tags["GithubInstallation"] = installation.ubid
    end
    tags
  end

  private

  def ignore_invalid_nic
    yield
  rescue ArgumentError,
    Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidAllocationIDNotFound,
    Aws::EC2::Errors::InvalidAddressIDNotFound,
    Aws::EC2::Errors::InvalidSubnetIDNotFound => e
    Clog.emit("ID not found for aws nic", {ignored_aws_nic_failure: Util.exception_to_hash(e, backtrace: nil)})
  end
end
