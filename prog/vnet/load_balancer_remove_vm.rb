# frozen_string_literal: true

class Prog::Vnet::LoadBalancerRemoveVm < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= vm.load_balancer
  end

  label def evacuate_vm
    load_balancer.vm_ports_by_vm_and_state(vm, ["up", "down"]).update(state: "evacuating")
    bud Prog::Vnet::CertServer, {subject_id: load_balancer.id, vm_id: vm.id}, :remove_cert_server if load_balancer.cert_enabled_lb?
    hop_wait_evacuate_vm
  end

  label def wait_evacuate_vm
    reap(:remove_vm)
  end

  label def remove_vm
    load_balancer.incr_update_load_balancer
    load_balancer.incr_rewrite_dns_records
    load_balancer.vm_ports_by_vm(vm).destroy
    load_balancer.load_balancer_vms_dataset[vm_id: vm.id].destroy
    pop "vm is removed from load balancer"
  end
end
