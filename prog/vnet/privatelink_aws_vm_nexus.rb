# frozen_string_literal: true

require "aws-sdk-elasticloadbalancingv2"

class Prog::Vnet::PrivatelinkAwsVmNexus < Prog::Base
  subject_is :privatelink_aws_vm

  def pl
    privatelink_aws_vm.privatelink_aws_resource
  end

  def elb_client
    location = pl.location
    Aws::ElasticLoadBalancingV2::Client.new(
      region: location.name,
      credentials: location.location_credential.credentials
    )
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless strand.label == "destroy"
    end
  end

  label def start
    pl.ports.each do |port|
      privatelink_aws_vm.add_vm_port(privatelink_aws_port_id: port.id, state: "registering")
    end

    hop_wait
  end

  label def wait
    when_add_port_set? do
      hop_add_port
    end

    nap 30
  end

  label def add_port
    decr_add_port

    register_registering_vm_ports

    if privatelink_aws_vm.vm_ports_dataset.where(state: "registering").any?
      nap 5
    else
      hop_wait
    end
  end

  label def destroy
    decr_destroy

    deregister_all_vm_ports

    privatelink_aws_vm.destroy
    pop "PrivatelinkAwsVm destroyed"
  end

  private

  def register_registering_vm_ports
    vm = privatelink_aws_vm.vm
    return unless vm
    return unless (nic = pl.get_vm_nic(vm))

    private_ipv4 = nic.private_ipv4.network

    privatelink_aws_vm.vm_ports_dataset.where(state: "registering").eager(:privatelink_aws_port).all.each do |vm_port|
      port = vm_port.privatelink_aws_port
      next unless port.target_group_arn

      begin
        elb_client.register_targets(
          target_group_arn: port.target_group_arn,
          targets: [{id: private_ipv4.to_s, port: port.dst_port}]
        )
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        next
      end

      PrivatelinkAwsVmPort.where(id: vm_port.id, state: "registering").update(state: "registered")
    end
  end

  def deregister_all_vm_ports
    vm = privatelink_aws_vm.vm
    return unless vm
    return unless (nic = pl.get_vm_nic(vm))

    private_ipv4 = nic.private_ipv4.network

    privatelink_aws_vm.vm_ports_dataset.eager(:privatelink_aws_port).all.each do |vm_port|
      port = vm_port.privatelink_aws_port
      next unless port.target_group_arn

      begin
        elb_client.deregister_targets(
          target_group_arn: port.target_group_arn,
          targets: [{id: private_ipv4.to_s}]
        )
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        nil
      end
    end
  end
end
