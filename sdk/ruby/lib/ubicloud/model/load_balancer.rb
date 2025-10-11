# frozen_string_literal: true

module Ubicloud
  class LoadBalancer < Model
    set_prefix "1b"

    set_fragment "load-balancer"

    set_columns :id, :name, :location, :hostname, :algorithm, :stack, :health_check_endpoint, :health_check_protocol, :src_port, :dst_port, :subnet, :vms, :cert_enabled

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

    # Update the receiver with new parameters. Returns self.
    #
    # The +vms+ argument should be an array of virtual machines attached to the load
    # balancer.  The method will attach and detach virtual machines to the load
    # balancer as needed so that the list of attached virtual machines matches the
    # array given.
    def update(algorithm:, src_port:, dst_port:, health_check_endpoint:, cert_enabled:, vms:)
      merge_into_values(adapter.patch(_path, algorithm:, src_port:, dst_port:, health_check_endpoint:, cert_enabled:, vms:))
    end

    # Attach the given virtual machine to the firewall. Accepts either a Vm instance
    # or a virtual machine id string.  Returns a Vm instance.
    def attach_vm(vm)
      vm_action(vm, "/attach-vm")
    end

    # Detach the given virtual machine from the firewall. Accepts either a Vm instance
    # or a virtual machine id string.  Returns a Vm instance.
    def detach_vm(vm)
      vm_action(vm, "/detach-vm")
    end

    def toggle_ssl_certificate(cert_enabled:)
      merge_into_values(adapter.post(_path("/toggle-ssl-certificate"), cert_enabled:))
    end

    private

    # Internals of attach_vm/detach_vm
    def vm_action(vm, action)
      Vm.new(adapter, adapter.post(_path(action), vm_id: to_id(vm)))
    end
  end
end
