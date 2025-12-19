# frozen_string_literal: true

require "aws-sdk-elasticloadbalancingv2"

class Prog::Vnet::PrivatelinkAwsNexus < Prog::Base
  subject_is :privatelink_aws_resource

  def self.assemble(private_subnet_id:, ports: [[5432, 5432]], vm_ids: [])
    unless (ps = PrivateSubnet[private_subnet_id])
      fail "No existing private subnet"
    end

    unless ps.location.aws?
      fail "PrivateLink is only supported on AWS"
    end

    if ps.privatelink_aws_resource
      fail "PrivateLink already exists for this subnet"
    end

    DB.transaction do
      pl = PrivatelinkAwsResource.create(private_subnet_id: private_subnet_id)

      # Create ports
      ports.each do |src_port, dst_port|
        PrivatelinkAwsPort.create(
          privatelink_aws_resource_id: pl.id,
          src_port: src_port,
          dst_port: dst_port
        )
      end

      # Add initial VMs
      vm_ids.each do |vm_id|
        vm = Vm[vm_id]
        next unless vm

        pl_vm = PrivatelinkAwsVm.create(
          privatelink_aws_resource_id: pl.id,
          vm_id: vm_id
        )

        # Create vm_port associations for each port
        pl.ports.each do |port|
          PrivatelinkAwsVmPort.create(
            privatelink_aws_vm_id: pl_vm.id,
            privatelink_aws_port_id: port.id,
            state: "registering"
          )
        end
      end

      Strand.create_with_id(pl, prog: "Vnet::PrivatelinkAwsNexus", label: "start")
    end
  end

  def elb_client
    location = privatelink_aws_resource.location
    Aws::ElasticLoadBalancingV2::Client.new(
      region: location.name,
      credentials: location.location_credential.credentials
    )
  end

  def ec2_client
    privatelink_aws_resource.location.location_credential.client
  end

  def private_subnet
    privatelink_aws_resource.private_subnet
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_nlb_deletion"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def start
    # Validate we have at least one port
    if privatelink_aws_resource.ports.empty?
      fail "PrivateLink must have at least one port"
    end

    # Get subnet info from any VM in the subnet or from the private subnet's resources
    # We need at least one NIC in the subnet to get the AWS subnet ID
    nic = if privatelink_aws_resource.vms.first
      # Get NIC from a registered VM
      privatelink_aws_resource.get_vm_nic(privatelink_aws_resource.vms.first)
    else
      # Get any NIC from the private subnet
      private_subnet.nics.first
    end

    unless nic&.nic_aws_resource
      fail "Cannot create PrivateLink: subnet has no NICs with AWS resources. Create a VM in this subnet first."
    end

    subnet_id = nic.nic_aws_resource.subnet_id

    # Create Network Load Balancer
    nlb_response = elb_client.create_load_balancer(
      name: "pl-#{privatelink_aws_resource.ubid.to_s[..16]}",
      type: "network",
      scheme: "internal",
      ip_address_type: "ipv4",
      subnets: [subnet_id],
      tags: [
        {key: "resource_id", value: privatelink_aws_resource.id.to_s},
        {key: "subnet_id", value: private_subnet.id.to_s}
      ]
    )

    nlb_arn = nlb_response.load_balancers.first.load_balancer_arn
    privatelink_aws_resource.update(nlb_arn: nlb_arn)

    hop_wait_nlb_active
  end

  label def wait_nlb_active
    nlb_desc = elb_client.describe_load_balancers(
      load_balancer_arns: [privatelink_aws_resource.nlb_arn]
    )
    state = nlb_desc.load_balancers.first.state.code

    if state == "active"
      hop_create_target_groups_and_listeners
    else
      puts "NLB is not active yet, waiting..."
      puts "State: #{state}"
      puts "NLB ARN: #{privatelink_aws_resource.nlb_arn}"
      puts "NLB Description: #{nlb_desc.load_balancers.first.inspect}"
      nap 5
    end
  end

  label def create_target_groups_and_listeners
    # Get VPC ID from the private subnet
    vpc_id = private_subnet.private_subnet_aws_resource.vpc_id

    # Create one target group and listener for each port
    privatelink_aws_resource.ports.each do |port|
      # Create target group
      tg_response = elb_client.create_target_group(
        name: "pl-tg-#{port.src_port}-#{privatelink_aws_resource.ubid.to_s[..10]}",
        protocol: "TCP",
        port: port.dst_port,
        vpc_id: vpc_id,
        target_type: "ip",
        health_check_protocol: "TCP",
        health_check_port: port.dst_port.to_s,
        health_check_interval_seconds: 30,
        healthy_threshold_count: 3,
        unhealthy_threshold_count: 3,
        tags: [
          {key: "resource_id", value: privatelink_aws_resource.id.to_s},
          {key: "port_id", value: port.id.to_s}
        ]
      )

      target_group_arn = tg_response.target_groups.first.target_group_arn
      port.update(target_group_arn: target_group_arn)

      # Create listener
      listener_response = elb_client.create_listener(
        load_balancer_arn: privatelink_aws_resource.nlb_arn,
        protocol: "TCP",
        port: port.src_port,
        default_actions: [
          {
            type: "forward",
            target_group_arn: target_group_arn
          }
        ]
      )

      listener_arn = listener_response.listeners.first.listener_arn
      port.update(listener_arn: listener_arn)
    end

    hop_register_initial_targets
  end

  label def register_initial_targets
    # Register all VMs to all target groups
    privatelink_aws_resource.vm_ports_dataset.where(state: "registering").each do |vm_port|
      vm = vm_port.vm
      nic = privatelink_aws_resource.get_vm_nic(vm)
      next unless nic

      private_ipv4 = nic.private_ipv4.network
      port = vm_port.privatelink_aws_port

      begin
        elb_client.register_targets(
          target_group_arn: port.target_group_arn,
          targets: [
            {id: private_ipv4.to_s, port: port.dst_port}
          ]
        )
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        # Target group deleted, skip registration
        next
      end

      vm_port.update(state: "registered")
    end

    hop_create_endpoint_service
  end

  label def create_endpoint_service
    endpoint_service_response = ec2_client.create_vpc_endpoint_service_configuration(
      network_load_balancer_arns: [privatelink_aws_resource.nlb_arn],
      acceptance_required: false,
      tag_specifications: [
        {
          resource_type: "vpc-endpoint-service",
          tags: [
            {key: "Name", value: "pl-#{privatelink_aws_resource.ubid.to_s[..16]}"},
            {key: "resource_id", value: privatelink_aws_resource.id.to_s}
          ]
        }
      ]
    )

    service_name = endpoint_service_response.service_configuration.service_name
    service_id = endpoint_service_response.service_configuration.service_id

    privatelink_aws_resource.update(
      service_name: service_name,
      service_id: service_id
    )

    hop_wait
  end

  label def wait
    # Handle semaphores for dynamic operations
    when_update_targets_set? do
      hop_update_targets
    end

    when_add_port_set? do
      hop_add_port
    end

    when_remove_port_set? do
      hop_remove_port
    end

    when_add_vm_set? do
      hop_add_vm
    end

    when_remove_vm_set? do
      hop_remove_vm
    end

    nap 30
  end

  label def update_targets
    decr_update_targets

    # Deregister targets that are marked as deregistering
    privatelink_aws_resource.vm_ports_dataset.where(state: "deregistering").each do |vm_port|
      vm = vm_port.vm
      nic = privatelink_aws_resource.get_vm_nic(vm)
      next unless nic

      private_ipv4 = nic.private_ipv4.network
      port = vm_port.privatelink_aws_port

      begin
        elb_client.deregister_targets(
          target_group_arn: port.target_group_arn,
          targets: [{id: private_ipv4.to_s}]
        )
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        # Target already deregistered or target group deleted, that's fine
      end

      vm_port.update(state: "deregistered")
    end

    # Register new targets that are marked as registering
    privatelink_aws_resource.vm_ports_dataset.where(state: "registering").each do |vm_port|
      vm = vm_port.vm
      nic = privatelink_aws_resource.get_vm_nic(vm)
      next unless nic

      private_ipv4 = nic.private_ipv4.network
      port = vm_port.privatelink_aws_port

      begin
        elb_client.register_targets(
          target_group_arn: port.target_group_arn,
          targets: [
            {id: private_ipv4.to_s, port: port.dst_port}
          ]
        )
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        # Target group deleted, skip registration
        next
      end

      vm_port.update(state: "registered")
    end

    # Clean up deregistered vm_ports
    privatelink_aws_resource.vm_ports_dataset.where(state: "deregistered").each(&:destroy)

    # Clean up VMs that have no more ports
    privatelink_aws_resource.privatelink_aws_vms.each do |pl_vm|
      pl_vm.destroy if pl_vm.vm_ports.empty?
    end

    hop_wait
  end

  label def add_port
    decr_add_port

    # Find ports that don't have target groups yet
    privatelink_aws_resource.ports.each do |port|
      next if port.target_group_arn

      # Get VPC info
      nic = privatelink_aws_resource.vms.first&.nics&.first
      next unless nic

      ps = nic.private_subnet
      vpc_id = ps.private_subnet_aws_resource.vpc_id

      # Create target group
      tg_response = elb_client.create_target_group(
        name: "pl-tg-#{port.src_port}-#{privatelink_aws_resource.ubid.to_s[..10]}",
        protocol: "TCP",
        port: port.dst_port,
        vpc_id: vpc_id,
        target_type: "ip",
        health_check_protocol: "TCP",
        health_check_port: port.dst_port.to_s,
        health_check_interval_seconds: 30,
        healthy_threshold_count: 3,
        unhealthy_threshold_count: 3,
        tags: [
          {key: "resource_id", value: privatelink_aws_resource.id.to_s},
          {key: "port_id", value: port.id.to_s}
        ]
      )

      target_group_arn = tg_response.target_groups.first.target_group_arn
      port.update(target_group_arn: target_group_arn)

      # Create listener
      listener_response = elb_client.create_listener(
        load_balancer_arn: privatelink_aws_resource.nlb_arn,
        protocol: "TCP",
        port: port.src_port,
        default_actions: [
          {
            type: "forward",
            target_group_arn: target_group_arn
          }
        ]
      )

      listener_arn = listener_response.listeners.first.listener_arn
      port.update(listener_arn: listener_arn)

      # Register all existing VMs to this new port
      port.vm_ports_dataset.where(state: "registering").each do |vm_port|
        vm = vm_port.vm
        nic = privatelink_aws_resource.get_vm_nic(vm)
        next unless nic

        private_ipv4 = nic.private_ipv4.network

        begin
          elb_client.register_targets(
            target_group_arn: target_group_arn,
            targets: [
              {id: private_ipv4.to_s, port: port.dst_port}
            ]
          )
        rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
          # Target group deleted, skip registration
          next
        end

        vm_port.update(state: "registered")
      end
    end

    hop_wait
  end

  label def remove_port
    decr_remove_port

    # Find ports marked for deletion (have deregistering vm_ports)
    ports_to_remove = privatelink_aws_resource.ports.select { |port|
      port.vm_ports_dataset.where(state: "deregistering").count > 0
    }

    ports_to_remove.each do |port|
      # Deregister all targets first
      port.vm_ports_dataset.each do |vm_port|
        vm = vm_port.vm
        nic = privatelink_aws_resource.get_vm_nic(vm)
        next unless nic

        private_ipv4 = nic.private_ipv4.network

        begin
          elb_client.deregister_targets(
            target_group_arn: port.target_group_arn,
            targets: [{id: private_ipv4.to_s}]
          )
        rescue Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
          # Already deregistered or target group deleted, that's fine
        end

        vm_port.destroy
      end

      # Delete listener
      if port.listener_arn
        begin
          elb_client.delete_listener(listener_arn: port.listener_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
          # Already deleted, that's fine
        end
      end

      # Delete target group
      if port.target_group_arn
        begin
          elb_client.delete_target_group(target_group_arn: port.target_group_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
          # Already deleted, that's fine
        end
      end

      # Delete port record
      port.destroy
    end

    hop_wait
  end

  label def add_vm
    decr_add_vm

    # This is handled by update_targets
    hop_update_targets
  end

  label def remove_vm
    decr_remove_vm

    # This is handled by update_targets
    hop_update_targets
  end

  label def destroy
    decr_destroy

    # Delete VPC Endpoint Service
    if privatelink_aws_resource.service_id
      begin
        ec2_client.delete_vpc_endpoint_service_configurations(
          service_ids: [privatelink_aws_resource.service_id]
        )
        # Wait a bit for the service to start deleting
        nap 5
      rescue Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound
        # Already deleted, that's fine
      end
    end

    # Wait for VPC Endpoint Service to be fully deleted
    if privatelink_aws_resource.service_id
      begin
        # Check if service still exists
        ec2_client.describe_vpc_endpoint_service_configurations(
          service_ids: [privatelink_aws_resource.service_id]
        )
        # Service still exists, wait and retry
        nap 10
        return
      rescue Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound
        # Service is deleted, we can proceed
      end
    end

    # Delete listeners and target groups for each port
    privatelink_aws_resource.ports.each do |port|
      # Delete listener
      if port.listener_arn
        begin
          elb_client.delete_listener(listener_arn: port.listener_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
          # Already deleted, that's fine
        end
      end

      # Deregister all targets from this target group
      if port.target_group_arn
        port.vm_ports.each do |vm_port|
          vm = vm_port.vm
          nic = privatelink_aws_resource.get_vm_nic(vm)
          next unless nic

          private_ipv4 = nic.private_ipv4.network

          begin
            elb_client.deregister_targets(
              target_group_arn: port.target_group_arn,
              targets: [{id: private_ipv4.to_s}]
            )
          rescue Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
            # Already deregistered or target group deleted, that's fine
          end
        end

        # Delete target group
        begin
          elb_client.delete_target_group(target_group_arn: port.target_group_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
          # Already deleted, that's fine
        end
      end
    end

    # Delete Load Balancer
    if privatelink_aws_resource.nlb_arn
      begin
        elb_client.delete_load_balancer(load_balancer_arn: privatelink_aws_resource.nlb_arn)
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        # Already deleted, that's fine
      rescue Aws::ElasticLoadBalancingV2::Errors::ResourceInUse
        # NLB is still associated with VPC Endpoint Service, wait and retry
        nap 10
        return
      end
    end

    hop_wait_nlb_deletion
  end

  label def wait_nlb_deletion
    # Wait for NLB to be fully deleted before destroying the record
    if privatelink_aws_resource.nlb_arn
      begin
        nlb_desc = elb_client.describe_load_balancers(
          load_balancer_arns: [privatelink_aws_resource.nlb_arn]
        )
        # NLB still exists, wait
        nap 10
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        # NLB is deleted, we can proceed
        privatelink_aws_resource.destroy
        pop "PrivateLink deleted"
      end
    else
      privatelink_aws_resource.destroy
      pop "PrivateLink deleted"
    end
  end
end
