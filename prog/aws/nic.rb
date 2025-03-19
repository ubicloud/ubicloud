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
      tag_specifications: tag_specifications("network-interface")
    })
    network_interface_id = network_interface_response.network_interface.network_interface_id

    client.assign_ipv_6_addresses({
      network_interface_id:,
      ipv_6_address_count: 1
    })

    nic.update(name: network_interface_id)
    hop_wait_network_interface_created
  end

  label def wait_network_interface_created
    network_interface_response = client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic.name]}, {name: "tag:Ubicloud", values: ["true"]}]}).network_interfaces[0]
    if network_interface_response.status == "available"
      eip_response = client.allocate_address

      # Associate the Elastic IP with your network interface
      client.associate_address({
        allocation_id: eip_response.allocation_id,
        network_interface_id: nic.name
      })

      pop "nic created"
    end

    nap 1
  end

  label def destroy
    ignore_invalid_nic do
      client.delete_network_interface({network_interface_id: nic.name})
    end
    hop_release_eip
  end

  label def release_eip
    ignore_invalid_nic do
      if (eip_response = client.describe_addresses({filters: [{name: "network-interface-id", values: [nic.name]}]}).addresses[0])
        client.release_address({allocation_id: eip_response.allocation_id})
      end
    end
    pop "nic destroyed"
  end

  def client
    @client ||= nic.private_subnet.location.location_credential.client
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

  private

  def ignore_invalid_nic
    yield
  rescue Aws::EC2::Errors::InvalidNetworkInterfaceIDNotFound
  end
end
