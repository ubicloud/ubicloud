# frozen_string_literal: true

module Ubicloud
  class LoadBalancer < Model
    set_prefix "1b"

    set_fragment "load-balancer"

    set_columns :id, :name, :location, :hostname, :algorithm, :stack, :health_check_endpoint, :health_check_protocol, :src_port, :dst_port, :subnet, :vms

    set_associations do
      {
        subnet: PrivateSubnet,
        vms: Vm
      }
    end

    set_create_param_defaults do |params|
      params[:algorithm] ||= "round_robin"
      params[:stack] ||= "dual"
      params[:health_check_protocol] ||= "http"
    end

    def update(algorithm:, src_port:, dst_port:, health_check_endpoint:, vms:)
      LoadBalancer.new(adapter, adapter.patch(path, algorithm:, src_port:, dst_port:, health_check_endpoint:, vms:))
    end

    def attach_vm(vm)
      vm_action(vm, "/attach-vm")
    end

    def detach_vm(vm)
      vm_action(vm, "/detach-vm")
    end

    private

    def vm_action(vm, action)
      vm = vm.id if vm.is_a?(Vm)
      Vm.new(adapter, adapter.post(path(action), vm_id: vm))
    end
  end
end
