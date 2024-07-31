# frozen_string_literal: true

require "acme-client"
require "openssl"

class Prog::Vnet::LoadBalancerNexus < Prog::Base
  subject_is :load_balancer
  semaphore :destroy, :update_load_balancer, :rewrite_dns_records, :refresh_cert

  def self.assemble(private_subnet_id, name: nil, algorithm: "round_robin", src_port: nil, dst_port: nil,
    health_check_endpoint: "/up", health_check_interval: 30, health_check_timeout: 15,
    health_check_up_threshold: 3, health_check_down_threshold: 2)

    unless (ps = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    Validation.validate_name(name)

    DB.transaction do
      lb = LoadBalancer.create_with_id(
        private_subnet_id: private_subnet_id, name: name, algorithm: algorithm,
        src_port: src_port, dst_port: dst_port, health_check_endpoint: health_check_endpoint,
        health_check_interval: health_check_interval, health_check_timeout: health_check_timeout,
        health_check_up_threshold: health_check_up_threshold, health_check_down_threshold: health_check_down_threshold
      )
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

    when_rewrite_dns_records_set? do
      rewrite_dns_records
      decr_rewrite_dns_records
    end

    hop_create_new_health_probe if strand.children_dataset.count < load_balancer.vms_dataset.count
    hop_create_new_cert if load_balancer.need_certificates?

    nap 5
  end

  label def create_new_cert
    cert = Prog::Vnet::CertNexus.assemble(load_balancer.hostname, Prog::Vnet::LoadBalancerNexus.dns_zone.id).subject
    load_balancer.add_cert(cert)
    hop_wait_cert_provisioning
  end

  label def wait_cert_provisioning
    nap 60 if load_balancer.need_certificates?
    hop_wait
  end

  label def create_new_health_probe
    vms = load_balancer.vms
    vms_getting_probed = strand.children_dataset.where(prog: "Vnet::LoadBalancerHealthProbes").map { |st| st.stack[0]["vm_id"] }
    vms.reject { vms_getting_probed.include?(_1.id) }.each do |vm|
      bud Prog::Vnet::LoadBalancerHealthProbes, {"vm_id" => vm.id, "subject_id" => load_balancer.id}, :health_probe
    end

    hop_wait
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
    # The following if statement makes sure that it's OK to not have dns_zone
    # only if it's not in production.
    if (dns_zone = Prog::Vnet::LoadBalancerNexus.dns_zone) && (Config.production? || dns_zone)
      dns_zone.delete_record(record_name: load_balancer.hostname)
    end

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

  def rewrite_dns_records
    Prog::Vnet::LoadBalancerNexus.dns_zone&.delete_record(record_name: load_balancer.hostname)

    load_balancer.vms_to_dns.map do |vm|
      Prog::Vnet::LoadBalancerNexus.dns_zone&.insert_record(record_name: load_balancer.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s) if vm.ephemeral_net4
      Prog::Vnet::LoadBalancerNexus.dns_zone&.insert_record(record_name: load_balancer.hostname, type: "AAAA", ttl: 10, data: vm.ephemeral_net6.nth(2).to_s)
    end
  end

  def self.dns_zone
    @@dns_zone ||= DnsZone[project_id: Config.load_balancer_service_project_id, name: Config.load_balancer_service_hostname]
  end
end
