# frozen_string_literal: true

class Prog::Vnet::LoadBalancerNexus < Prog::Base
  subject_is :load_balancer
  semaphore :destroy, :update_load_balancer, :rewrite_dns_records

  def self.assemble(private_subnet_id, name: nil, algorithm: "round_robin", src_port: nil, dst_port: nil)
    unless (ps = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = LoadBalancer.generate_ubid

    DB.transaction do
      lb = LoadBalancer.create(
        private_subnet_id: private_subnet_id, name: name, algorithm: algorithm,
        src_port: src_port, dst_port: dst_port
      ) { _1.id = ubid.to_uuid }
      lb.associate_with_project(ps.projects.first)

      Strand.create(prog: "Vnet::LoadBalancerNexus", label: "wait") { _1.id = ubid.to_uuid }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy" && strand.label != "wait_destroy"
    end
  end

  label def wait
    when_update_load_balancer_set? do
      hop_update_vm_load_balancers
    end

    when_rewrite_dns_records_set? do
      rewrite_dns_records
      decr_rewrite_dns_records
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
    if leaf?
      decr_update_load_balancer
      hop_wait
    end
    donate
  end

  label def destroy
    decr_destroy
    strand.children.each { _1.destroy }
    Prog::Vnet::LoadBalancerNexus.dns_zone&.delete_record(record_name: load_balancer.hostname)

    load_balancer.vms.each do |vm|
      bud Prog::Vnet::UpdateLoadBalancer, {"subject_id" => vm.id, "load_balancer_id" => load_balancer.id}, :remove_load_balancer
    end

    hop_wait_destroy
  end

  label def wait_destroy
    reap
    if leaf?
      DB[:load_balancers_vms].where(load_balancer_id: load_balancer.id).delete(force: true)
      load_balancer.destroy

      pop "load balancer deleted"
    end

    nap 5
  end

  def rewrite_dns_records
    Prog::Vnet::LoadBalancerNexus.dns_zone&.delete_record(record_name: load_balancer.hostname)
    load_balancer.vms.each do |vm|
      Prog::Vnet::LoadBalancerNexus.dns_zone&.insert_record(record_name: load_balancer.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s) if vm.ephemeral_net4
      Prog::Vnet::LoadBalancerNexus.dns_zone&.insert_record(record_name: load_balancer.hostname, type: "AAAA", ttl: 10, data: vm.ephemeral_net6.nth(2).to_s)
    end
  end

  def self.dns_zone
    @@dns_zone ||= DnsZone[project_id: Config.load_balancer_service_project_id, name: Config.load_balancer_service_hostname]
  end
end
