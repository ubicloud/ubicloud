# frozen_string_literal: true

class Prog::Vnet::LoadBalancerNexus < Prog::Base
  subject_is :load_balancer
  semaphore :destroy, :update_load_balancer

  def self.assemble(private_subnet_id, name: nil, algorithm: "round_robin", src_port: nil, dst_port: nil)

    unless (ps = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    Validation.validate_name(name)

    DB.transaction do
      lb = LoadBalancer.create_with_id(
        private_subnet_id: private_subnet_id, name: name, algorithm: algorithm,
        src_port: src_port, dst_port: dst_port)
      lb.associate_with_project(ps.projects.first)

      Strand.create(prog: "Vnet::LoadBalancerNexus", label: "wait") { _1.id = lb.id }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless %w[destroy wait_destroy].include?(strand.label)
    end
  end

  label def wait
    when_update_load_balancer_set? do
      hop_update_vm_load_balancers
    end

    nap 5
  end

  label def update_vm_load_balancers
    load_balancer.vms.each do |vm|
      bud Prog::Vnet::UpdateLoadBalancer, {"subject_id" => vm.id, "load_balancer_id" => load_balancer.id}, :update_load_balancer
    end

    hop_wait_update_vm_load_balancers
  end

  label def wait_update_vm_load_balancers
    reap
    if strand.children_dataset.where(prog: "Vnet::UpdateLoadBalancer").all? { _1.exitval == "load balancer is updated" } || strand.children.empty?
      decr_update_load_balancer
      hop_wait
    end

    nap 1
  end

  label def destroy
    decr_destroy
    strand.children.map { _1.destroy }

    load_balancer.vms.each do |vm|
      bud Prog::Vnet::UpdateLoadBalancer, {"subject_id" => vm.id, "load_balancer_id" => load_balancer.id}, :remove_load_balancer
    end

    hop_wait_destroy
  end

  label def wait_destroy
    reap
    if leaf?
      load_balancer.projects.each { |prj| load_balancer.dissociate_with_project(prj) }
      load_balancer.destroy

      pop "load balancer deleted"
    end

    nap 5
  end
end
