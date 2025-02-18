# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::Aws::Allocator < Prog::Base
  subject_is :private_subnet_aws_resource

  label def create_aws_subnet
    vpc_response = client.create_vpc({cidr_block: private_subnet_aws_resource.private_subnet.net4.to_s,
      amazon_provided_ipv_6_cidr_block: true})
    private_subnet_aws_resource.update(vpc_id: vpc_response.vpc.vpc_id)
    hop_wait_vpc_created
  end

  label def wait_vpc_created
    vpc = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).vpcs[0]
    puts "vpc: #{vpc}"
    if vpc.state == "available"
      security_group_response = client.create_security_group({
        group_name: "aws-us-east-1-#{private_subnet_aws_resource.id}",
        description: "Security group for aws-us-east-1-#{private_subnet_aws_resource.id}",
        vpc_id: private_subnet_aws_resource.vpc_id
      })

      client.authorize_security_group_ingress({
        group_id: security_group_response.group_id,
        ip_permissions: [{
          ip_protocol: "tcp",
          from_port: 22,
          to_port: 22,
          ip_ranges: [{cidr_ip: "0.0.0.0/0"}]
        }]
      })
      hop_create_subnet
    end
    nap 1
  end

  label def create_subnet
    vpc_response = client.describe_vpcs({filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]}).vpcs[0]
    ipv_6_cidr_block = vpc_response.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block.gsub("/56", "")
    subnet_response = client.create_subnet({
      vpc_id: vpc_response.vpc_id,
      cidr_block: private_subnet_aws_resource.private_subnet.net4.to_s,
      ipv_6_cidr_block: "#{ipv_6_cidr_block}/64",
      availability_zone: "us-east-1a"
    })

    subnet_id = subnet_response.subnet.subnet_id
    # Enable auto-assign ipv_6 addresses for the subnet
    client.modify_subnet_attribute({
      subnet_id: subnet_id,
      assign_ipv_6_address_on_creation: {value: true}
    })
    private_subnet_aws_resource.update(subnet_id: subnet_id)
    hop_wait_subnet_created
  end

  label def wait_subnet_created
    subnet_response = client.describe_subnets({filters: [{name: "subnet-id", values: [private_subnet_aws_resource.subnet_id]}]}).subnets[0]
    if subnet_response.state == "available"
      hop_create_route_table
    end
    nap 1
  end

  label def create_route_table
    # Step 3: Update the route table for ipv_6 traffic
    route_table_response = client.describe_route_tables({
      filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]
    })
    route_table_id = route_table_response.route_tables[0].route_table_id
    private_subnet_aws_resource.update(route_table_id: route_table_id)
    internet_gateway_response = client.create_internet_gateway
    internet_gateway_id = internet_gateway_response.internet_gateway.internet_gateway_id
    private_subnet_aws_resource.update(internet_gateway_id: internet_gateway_id)
    client.attach_internet_gateway({
      internet_gateway_id: internet_gateway_id,
      vpc_id: private_subnet_aws_resource.vpc_id
    })

    client.create_route({
      route_table_id: route_table_id,
      destination_ipv_6_cidr_block: "::/0",
      gateway_id: internet_gateway_id
    })

    client.create_route({
      route_table_id: route_table_id,
      destination_ipv_6_cidr_block: "::/0",
      gateway_id: internet_gateway_id
    })

    client.associate_route_table({
      route_table_id: route_table_id,
      subnet_id: private_subnet_aws_resource.subnet_id
    })

    pop "subnet created"
  end

  label def create_network_interface
    # Step 4: Enable prefix delegation on the network interface
    network_interface_response = client.create_network_interface({
      subnet_id: private_subnet_aws_resource.subnet_id,
      ipv_6_prefix_count: 1
    })
    client.assign_ipv_6_addresses({
      network_interface_id: network_interface_response.network_interface.network_interface_id,
      ipv_6_address_count: 1
    })

    network_interface_id = network_interface_response.network_interface.network_interface_id
    nic_aws_resource.update(network_interface_id: network_interface_id)
    hop_wait_network_interface_created
  end

  label def wait_network_interface_created
    network_interface_response = client.describe_network_interfaces({filters: [{name: "network-interface-id", values: [nic_aws_resource.network_interface_id]}]}).network_interfaces[0]
    if network_interface_response.status == "available"
      eip_response = client.allocate_address({
        domain: "vpc" # Required for VPC-based instances
      })

      # Associate the Elastic IP with your network interface
      client.associate_address({
        allocation_id: eip_response.allocation_id,
        network_interface_id: nic_aws_resource.network_interface_id
      })

      # nic_aws_resource.update(elastic_ip_id: eip_response.allocation_id)
      pop "eip created"
    end

    nap 1
  end

  label def launch_instance
    # key_pair_response = client.create_key_pair({
    #   key_name: "aws-us-east-1-#{nic_aws_resource.id}"
    # })
    # key_pair_id = key_pair_response.key_pair_id
    # nic_aws_resource.update(key_pair_id: key_pair_id)
    # Define user data script to set a custom username
    user_data = <<~USER_DATA
      #!/bin/bash
      custom_user="#{vm.unix_user}"

      # Create the custom user
      adduser $custom_user --disabled-password --gecos ""

      # Add the custom user to the sudo group
      usermod -aG sudo $custom_user

      # Set up SSH access for the custom user
      mkdir -p /home/$custom_user/.ssh
      cp /home/ubuntu/.ssh/authorized_keys /home/$custom_user/.ssh/
      chown -R $custom_user:$custom_user /home/$custom_user/.ssh
      chmod 700 /home/$custom_user/.ssh
      chmod 600 /home/$custom_user/.ssh/authorized_keys
      echo "#{vm.public_key}" > /home/$custom_user/.ssh/authorized_keys

      # Optional: Disable the default user (e.g., 'ubuntu' or 'ec2-user')
      # usermod -L ubuntu
    USER_DATA

    instance_response = client.run_instances({
      image_id: "ami-0e4eca65b3e6d5949", # AMI ID
      instance_type: "t3.small", # Instance type
      # key_name: "aws-us-east-1-e5a22500-4e39-86ac-b38b-1747c703b97a", # Key pair name
      block_device_mappings: [
        {
          device_name: "/dev/sda1",
          ebs: {
            encrypted: true,
            delete_on_termination: true,
            iops: 3000,
            volume_size: 100,
            volume_type: "gp3",
            throughput: 125
          }
        }
      ],
      network_interfaces: [
        {
          network_interface_id: nic_aws_resource.network_interface_id,
          device_index: 0
        }
      ],
      credit_specification: {
        cpu_credits: "standard"
      },
      metadata_options: {
        http_endpoint: "enabled",
        http_put_response_hop_limit: 2,
        http_tokens: "required"
      },
      private_dns_name_options: {
        hostname_type: "ip-name",
        enable_resource_name_dns_a_record: false,
        enable_resource_name_dns_aaaa_record: false
      },
      min_count: 1, # Minimum number of instances to launch
      max_count: 1,  # Maximum number of instances to launch
      user_data: Base64.encode64(user_data)
    })
    instance_id = instance_response.instances[0].instance_id
    nic_aws_resource.update(instance_id: instance_id)
    hop_wait_instance_created
  end

  label def wait_instance_created
    instance_response = client.describe_instances({filters: [{name: "instance-id", values: [nic_aws_resource.instance_id]}]}).reservations[0].instances[0]
    puts "instance_response: #{instance_response}"
    if instance_response.state.name == "running"
      pop JSON.pretty_generate(instance_response).to_s
    end
    nap 1
  end

  label def wait
    pop "instance created"
  end

  label def destroy
    client.terminate_instances({instance_ids: [nic_aws_resource.instance_id]})
    client.release_address({allocation_id: nic_aws_resource.elastic_ip_id})
    client.detach_network_interface({network_interface_id: nic_aws_resource.network_interface_id})
    client.delete_network_interface({network_interface_id: nic_aws_resource.network_interface_id})
    client.delete_security_group({group_id: private_subnet_aws_resource.security_group_id})
    client.detach_internet_gateway({
      internet_gateway_id: private_subnet_aws_resource.internet_gateway_id,
      vpc_id: private_subnet_aws_resource.vpc_id
    })
    client.delete_internet_gateway(internet_gateway_id: private_subnet_aws_resource.internet_gateway_id)
    client.delete_subnet({subnet_id: private_subnet_aws_resource.subnet_id})
    client.delete_vpc({vpc_id: private_subnet_aws_resource.vpc_id})
    client.delete_route_table({route_table_id: private_subnet_aws_resource.route_table_id})

    pop "destroyed"
  end

  def vm
    @vm ||= Vm[strand.stack.first["vm_id"]]
  end

  def nic_aws_resource
    @nic_aws_resource ||= NicAwsResource[strand.stack.first["nic_id"]]
  end

  def access_key
    private_subnet_aws_resource.customer_aws_account.aws_account_access_key
  end

  def secret_key
    private_subnet_aws_resource.customer_aws_account.aws_account_secret_access_key
  end

  def region
    private_subnet_aws_resource.customer_aws_account.location
  end

  def client
    @client ||= Aws::EC2::Client.new(access_key_id: access_key, secret_access_key: secret_key, region: region)
  end
end
