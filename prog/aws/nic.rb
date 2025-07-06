# frozen_string_literal: true

require "aws-sdk-ec2"
class Prog::Aws::Nic < Prog::Base
  subject_is :nic

  label def create_network_interface
    network_interface_response = client.create_network_interface({
      subnet_id: nic.private_subnet.private_subnet_aws_resource.subnet_id,
      private_ip_address: nic.private_ipv4.network.to_s,
      ipv_6_prefix_count: 1,
      groups: [
        nic.private_subnet.private_subnet_aws_resource.security_group_id
      ],
      tag_specifications: Util.aws_tag_specifications("network-interface", nic.name),
      client_token: nic.id
    })
    network_interface_id = network_interface_response.network_interface.network_interface_id

    client.assign_ipv_6_addresses({network_interface_id:, ipv_6_address_count: 1}) if network_interface_response.network_interface.ipv_6_addresses.empty?

    nic.nic_aws_resource.update(network_interface_id:)
    hop_wait_network_interface_created
  end

  label def wait_network_interface_created
    network_interface_response = client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic.nic_aws_resource.network_interface_id]}, {name: "tag:Ubicloud", values: ["true"]}]}).network_interfaces[0]
    if network_interface_response.status == "available"
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
      nap 5 if client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic.nic_aws_resource.network_interface_id]}, {name: "tag:Ubicloud", values: ["true"]}]}).network_interfaces.first&.status == "in-use"
      client.delete_network_interface({network_interface_id: nic.nic_aws_resource.network_interface_id})
    end
    hop_release_eip
  end

  label def release_eip
    ignore_invalid_nic do
      allocation_id = nic.nic_aws_resource&.eip_allocation_id
      client.release_address({allocation_id: allocation_id}) if allocation_id
    end
    pop "nic destroyed"
  end

  def client
    @client ||= nic.private_subnet.location.location_credential.client
  end

  private

  def ignore_invalid_nic
    yield
  rescue Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound,
    Aws::EC2::Errors::InvalidAllocationIDNotFound,
    Aws::EC2::Errors::InvalidAddressIDNotFound => e
    Clog.emit("ID not found") { {exception: {error_code: e.code, error_message: e.message}} }
  end
end
