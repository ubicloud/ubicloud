# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-elasticloadbalancingv2"

class Prog::Vnet::PrivatelinkAwsNexus < Prog::Base
  subject_is :privatelink_aws_resource

  def self.assemble(private_subnet_id:, ports: [[5432, 5432]], vm_ids: [], description: nil)
    unless (ps = PrivateSubnet[private_subnet_id])
      fail "No existing private subnet"
    end

    unless ps.location.aws?
      fail "PrivateLink is only supported on AWS"
    end

    if ps.privatelink_aws_resource
      raise CloverError.new(409, "InvalidRequest", "PrivateLink already exists for this subnet")
    end

    DB.transaction do
      pl = PrivatelinkAwsResource.create(
        private_subnet_id:,
        description: description || "AWS PrivateLink endpoint for subnet #{ps.name}"
      )

      ports.each do |src_port, dst_port|
        PrivatelinkAwsPort.create(
          privatelink_aws_resource_id: pl.id,
          src_port:,
          dst_port:
        )
      end

      vm_ids.each do |vm_id|
        vm = Vm[vm_id]
        next unless vm

        pl_vm = pl.add_privatelink_aws_vm(vm_id:)
        Strand.create_with_id(pl_vm, prog: "Vnet::PrivatelinkAwsVmNexus", label: "start")
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
    fail "PrivateLink must have at least one port" if privatelink_aws_resource.ports.empty?

    nic = private_subnet.nics.find(&:nic_aws_resource)

    unless nic
      Clog.emit("PrivateLink waiting for a NIC with AWS resources", {privatelink_aws_resource: {ubid: privatelink_aws_resource.ubid}})
      nap 10
    end

    nlb_arn = elb_client.create_load_balancer(
      name: "pl-#{privatelink_aws_resource.ubid}",
      type: "network",
      scheme: "internal",
      ip_address_type: "ipv4",
      subnets: [nic.nic_aws_resource.subnet_id],
      tags: [
        {key: "ubid", value: privatelink_aws_resource.ubid.to_s},
        {key: "subnet_ubid", value: private_subnet.ubid.to_s}
      ]
    ).load_balancers.first.load_balancer_arn

    privatelink_aws_resource.update(nlb_arn:)

    hop_wait_nlb_active
  end

  label def wait_nlb_active
    nlb_state = elb_client.describe_load_balancers(
      load_balancer_arns: [privatelink_aws_resource.nlb_arn]
    ).load_balancers.first.state.code

    if nlb_state == "active"
      hop_create_target_groups_and_listeners
    else
      Clog.emit("NLB not yet active", {privatelink_aws_nlb: {state: nlb_state, arn: privatelink_aws_resource.nlb_arn}})
      nap 5
    end
  end

  label def create_target_groups_and_listeners
    vpc_id = private_subnet.private_subnet_aws_resource.vpc_id

    privatelink_aws_resource.ports.each do |port|
      target_group_arn = elb_client.create_target_group(
        name: "pl-tg-#{port.src_port}-#{privatelink_aws_resource.ubid}"[..31],
        protocol: "TCP",
        port: port.dst_port,
        vpc_id:,
        target_type: "ip",
        health_check_protocol: "TCP",
        health_check_port: port.dst_port.to_s,
        health_check_interval_seconds: 30,
        healthy_threshold_count: 3,
        unhealthy_threshold_count: 3,
        tags: [
          {key: "ubid", value: privatelink_aws_resource.ubid.to_s},
          {key: "port_ubid", value: port.ubid.to_s}
        ]
      ).target_groups.first.target_group_arn

      listener_arn = elb_client.create_listener(
        load_balancer_arn: privatelink_aws_resource.nlb_arn,
        protocol: "TCP",
        port: port.src_port,
        default_actions: [
          {
            type: "forward",
            target_group_arn:
          }
        ]
      ).listeners.first.listener_arn

      port.update(target_group_arn:, listener_arn:)
    end

    privatelink_aws_resource.privatelink_aws_vms.each do |pl_vm|
      pl_vm.incr_add_port if pl_vm.strand
    end

    hop_create_endpoint_service
  end

  label def create_endpoint_service
    result = ec2_client.create_vpc_endpoint_service_configuration(
      network_load_balancer_arns: [privatelink_aws_resource.nlb_arn],
      acceptance_required: false,
      tag_specifications: [
        {
          resource_type: "vpc-endpoint-service",
          tags: [
            {key: "Name", value: "pl-#{privatelink_aws_resource.ubid}"},
            {key: "ubid", value: privatelink_aws_resource.ubid.to_s}
          ]
        }
      ]
    )

    privatelink_aws_resource.update(
      service_name: result.service_configuration.service_name,
      service_id: result.service_configuration.service_id
    )

    hop_wait
  end

  label def wait
    when_add_port_set? do
      hop_add_port
    end

    when_remove_port_set? do
      hop_remove_port
    end

    nap 30
  end

  label def add_port
    decr_add_port

    privatelink_aws_resource.ports.each do |port|
      next if port.target_group_arn

      vpc_id = private_subnet.private_subnet_aws_resource.vpc_id

      target_group_arn = elb_client.create_target_group(
        name: "pl-tg-#{port.src_port}-#{privatelink_aws_resource.ubid}"[..31],
        protocol: "TCP",
        port: port.dst_port,
        vpc_id:,
        target_type: "ip",
        health_check_protocol: "TCP",
        health_check_port: port.dst_port.to_s,
        health_check_interval_seconds: 30,
        healthy_threshold_count: 3,
        unhealthy_threshold_count: 3,
        tags: [
          {key: "ubid", value: privatelink_aws_resource.ubid.to_s},
          {key: "port_ubid", value: port.ubid.to_s}
        ]
      ).target_groups.first.target_group_arn

      listener_arn = elb_client.create_listener(
        load_balancer_arn: privatelink_aws_resource.nlb_arn,
        protocol: "TCP",
        port: port.src_port,
        default_actions: [
          {
            type: "forward",
            target_group_arn:
          }
        ]
      ).listeners.first.listener_arn

      port.update(target_group_arn:, listener_arn:)

      privatelink_aws_resource.privatelink_aws_vms.each do |pl_vm|
        pl_vm.incr_add_port if pl_vm.strand
      end
    end

    hop_wait
  end

  label def remove_port
    decr_remove_port

    privatelink_aws_resource.ports_dataset
      .where(id: PrivatelinkAwsVmPort.where(state: "deregistering").select(:privatelink_aws_port_id))
      .each do |port|
        port.vm_ports_dataset.eager(privatelink_aws_vm: {vm: :nics}).all.each do |vm_port|
          vm = vm_port.vm
          next unless (nic = privatelink_aws_resource.get_vm_nic(vm))

          private_ipv4 = nic.private_ipv4.network

          begin
            elb_client.deregister_targets(
              target_group_arn: port.target_group_arn,
              targets: [{id: private_ipv4.to_s}]
            )
          rescue Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
            nil
          end

          vm_port.destroy
        end

        if port.listener_arn
          begin
            elb_client.delete_listener(listener_arn: port.listener_arn)
          rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
            nil
          end
        end

        if port.target_group_arn
          begin
            elb_client.delete_target_group(target_group_arn: port.target_group_arn)
          rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
            nil
          end
        end

        port.destroy
      end

    hop_wait
  end

  label def destroy
    decr_destroy

    privatelink_aws_resource.privatelink_aws_vms.each do |pl_vm|
      if pl_vm.strand
        pl_vm.incr_destroy
      else
        pl_vm.destroy
      end
    end

    nap 5 unless privatelink_aws_resource.privatelink_aws_vms_dataset.empty?

    if privatelink_aws_resource.service_id
      begin
        ec2_client.delete_vpc_endpoint_service_configurations(
          service_ids: [privatelink_aws_resource.service_id]
        )
      rescue Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound
        nil
      end

      begin
        result = ec2_client.describe_vpc_endpoint_service_configurations(
          service_ids: [privatelink_aws_resource.service_id]
        )
        nap 10 unless result.service_configurations.empty?
      rescue Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound
        nil
      end
    end

    privatelink_aws_resource.ports_dataset.all.each do |port|
      if port.listener_arn
        begin
          elb_client.delete_listener(listener_arn: port.listener_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
          nil
        end
      end

      if port.target_group_arn
        begin
          elb_client.delete_target_group(target_group_arn: port.target_group_arn)
        rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
          nil
        end
      end
    end

    if privatelink_aws_resource.nlb_arn
      begin
        elb_client.delete_load_balancer(load_balancer_arn: privatelink_aws_resource.nlb_arn)
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        nil
      rescue Aws::ElasticLoadBalancingV2::Errors::ResourceInUse
        nap 10
      end
    end

    hop_wait_nlb_deletion
  end

  label def wait_nlb_deletion
    if privatelink_aws_resource.nlb_arn
      begin
        elb_client.describe_load_balancers(
          load_balancer_arns: [privatelink_aws_resource.nlb_arn]
        )
        nap 10
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        privatelink_aws_resource.destroy
        pop "PrivateLink deleted"
      end
    else
      privatelink_aws_resource.destroy
      pop "PrivateLink deleted"
    end
  end
end
