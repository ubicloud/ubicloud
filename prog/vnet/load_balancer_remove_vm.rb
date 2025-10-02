# frozen_string_literal: true

class Prog::Vnet::LoadBalancerRemoveVm < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= vm&.load_balancer
  end

  label def before_run
    pop "vm is removed from load balancer" unless load_balancer
  end

  label def destroy_vm_ports_and_update_node
    load_balancer.vm_ports_by_vm(vm).destroy
    bud Prog::Vnet::UpdateLoadBalancerNode, {subject_id: vm.id, load_balancer_id: load_balancer.id}, :update_load_balancer
    hop_wait_for_node_update
  end

  label def wait_for_node_update
    reap(:initiate_cert_server_removal, nap: 5)
  end

  label def mark_vm_ports_as_evacuating
    load_balancer.vm_ports_by_vm_and_state(vm, ["up", "down"]).update(state: "evacuating")
    hop_initiate_cert_server_removal
  end

  label def initiate_cert_server_removal
    bud Prog::Vnet::CertServer, {subject_id: load_balancer.id, vm_id: vm.id}, :remove_cert_server if load_balancer.cert_enabled
    hop_wait_for_cert_server_removal
  end

  label def wait_for_cert_server_removal
    reap(:finalize_vm_removal, nap: 5)
  end

  label def finalize_vm_removal
    load_balancer.incr_update_load_balancer
    load_balancer.incr_rewrite_dns_records
    load_balancer.vm_ports_by_vm(vm).destroy
    load_balancer.load_balancer_vms_dataset.where(vm_id: vm.id).destroy
    pop "vm is removed from load balancer"
  end
end
