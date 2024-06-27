# frozen_string_literal: true

class Prog::Vnet::LoadBalancerNexus < Prog::Base
  subject_is :load_balancer
  semaphore :destroy, :update_load_balancer, :dns_challenge

  def self.assemble(private_subnet_id, name: nil, protocol: "tcp", src_port: nil,
    dst_port: nil, health_check_endpoint: nil, health_check_interval: nil,
    health_check_timeout: nil, health_check_unhealthy_threshold: nil, health_check_healthy_threshold: nil)

    unless PrivateSubnet[private_subnet_id]
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = LoadBalancer.generate_ubid

    DB.transaction do
      LoadBalancer.create(
        private_subnet_id: private_subnet_id, name: name, protocol: protocol,
        src_port: src_port, dst_port: dst_port, health_check_endpoint: health_check_endpoint,
        health_check_interval: health_check_interval, health_check_timeout: health_check_timeout,
        health_check_unhealthy_threshold: health_check_unhealthy_threshold,
        health_check_healthy_threshold: health_check_healthy_threshold
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Vnet::LoadBalancerNexus", label: "wait") { _1.id = ubid.to_uuid }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def wait
    when_update_load_balancer_set? do
      decr_update_load_balancer
      hop_update_vm_load_balancers
    end

    perform_health_check if load_balancer.health_check_endpoint

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
    if leaf?
      hop_wait
    end
    donate
  end

  label def destroy
    decr_destroy
    load_balancer.vms.map { _1.incr_update_load_balancer }
    DB[:load_balancers_vms].where(load_balancer_id: load_balancer.id).delete(force: true)
    load_balancer.destroy

    pop "load balancer deleted"
  end
end
