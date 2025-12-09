# frozen_string_literal: true

require "acme-client"
require "openssl"

class Prog::Vnet::LoadBalancerNexus < Prog::Base
  DEFAULT_HEALTH_CHECK_ENDPOINT = "/up"

  subject_is :load_balancer

  def self.assemble_with_multiple_ports(private_subnet_id, ports:, name: nil, algorithm: "round_robin",
    health_check_endpoint: DEFAULT_HEALTH_CHECK_ENDPOINT, health_check_interval: 30, health_check_timeout: 15,
    health_check_up_threshold: 3, health_check_down_threshold: 2, health_check_protocol: "http",
    custom_hostname_prefix: nil, custom_hostname_dns_zone_id: nil, stack: LoadBalancer::Stack::DUAL, cert_enabled: health_check_protocol == "https")

    unless (ps = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    Validation.validate_name(name)
    custom_hostname = if custom_hostname_prefix
      Validation.validate_name(custom_hostname_prefix)
      "#{custom_hostname_prefix}.#{DnsZone[custom_hostname_dns_zone_id].name}"
    end

    Validation.validate_load_balancer_stack(stack)
    ports = Validation.validate_load_balancer_ports(ports)

    DB.transaction do
      lb = LoadBalancer.create(
        private_subnet_id: private_subnet_id, name: name, algorithm: algorithm,
        custom_hostname: custom_hostname, custom_hostname_dns_zone_id: custom_hostname_dns_zone_id,
        stack: stack, project_id: ps.project_id,
        health_check_endpoint: health_check_endpoint,
        health_check_interval: health_check_interval,
        health_check_timeout: health_check_timeout,
        health_check_up_threshold: health_check_up_threshold,
        health_check_down_threshold: health_check_down_threshold,
        health_check_protocol: health_check_protocol,
        cert_enabled:
      )
      ports.each { |src_port, dst_port| LoadBalancerPort.create(load_balancer_id: lb.id, src_port:, dst_port:) }
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
    end
  end

  def self.assemble(private_subnet_id, name: nil, algorithm: "round_robin",
    health_check_endpoint: DEFAULT_HEALTH_CHECK_ENDPOINT, health_check_interval: 30, health_check_timeout: 15,
    health_check_up_threshold: 3, health_check_down_threshold: 2, health_check_protocol: "http", src_port: nil, dst_port: nil,
    custom_hostname_prefix: nil, custom_hostname_dns_zone_id: nil, stack: LoadBalancer::Stack::DUAL, cert_enabled: health_check_protocol == "https")

    assemble_with_multiple_ports(private_subnet_id, name:, algorithm:, health_check_endpoint:, health_check_interval:, health_check_timeout:,
      health_check_up_threshold:, health_check_down_threshold:, health_check_protocol:, ports: [[src_port, dst_port]], custom_hostname_prefix:, custom_hostname_dns_zone_id:, stack:, cert_enabled:)
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless %w[destroy wait_destroy].include?(strand.label)
    end
  end

  label def wait
    if load_balancer.need_certificates?
      load_balancer.incr_refresh_cert
      hop_create_new_cert
    end

    when_update_load_balancer_set? do
      hop_update_vm_load_balancers
    end

    when_rewrite_dns_records_set? do
      hop_rewrite_dns_records
    end

    if need_to_rewrite_dns_records?
      load_balancer.incr_rewrite_dns_records
    end

    nap 5
  end

  def need_to_rewrite_dns_records?
    return false unless load_balancer.dns_zone

    load_balancer.vms_to_dns.each do |vm|
      vm_dns_records(vm).each do |type, data|
        return true unless load_balancer.dns_zone.records_dataset.find { it.name == load_balancer.hostname + "." && it.type == type && it.data == data }
      end
    end

    false
  end

  def vm_dns_records(vm)
    ips = []
    ips << ["A", vm.ip4_string] if load_balancer.ipv4_enabled? && vm.ip4_string
    ips << ["AAAA", vm.ip6_string] if load_balancer.ipv6_enabled? && vm.ip6_string
    ips
  end

  label def create_new_cert
    cert = Prog::Vnet::CertNexus.assemble(load_balancer.hostname, load_balancer.dns_zone&.id).subject
    load_balancer.add_cert(cert)
    hop_wait_cert_provisioning
  end

  label def wait_cert_provisioning
    if load_balancer.need_certificates?
      nap 60
    elsif load_balancer.refresh_cert_set?
      load_balancer.vms.each do |vm|
        bud Prog::Vnet::CertServer, {"subject_id" => load_balancer.id, "vm_id" => vm.id}, :reshare_certificate
      end

      hop_wait_cert_broadcast
    end

    hop_wait
  end

  label def wait_cert_broadcast
    reap(nap: 1) do
      decr_refresh_cert
      load_balancer.certs_dataset.exclude(id: load_balancer.active_cert.id).all do |cert|
        LoadBalancerCert[cert_id: cert.id].destroy
      end
      hop_wait
    end
  end

  label def update_vm_load_balancers
    load_balancer.vms.each do |vm|
      bud Prog::Vnet::UpdateLoadBalancerNode, {"subject_id" => vm.id, "load_balancer_id" => load_balancer.id}, :update_load_balancer
    end

    hop_wait_update_vm_load_balancers
  end

  label def wait_update_vm_load_balancers
    reap(nap: 1) do
      decr_update_load_balancer
      hop_wait
    end
  end

  label def destroy
    decr_destroy
    strand.children.map { it.destroy }
    load_balancer.vms.each do |vm|
      bud Prog::Vnet::LoadBalancerRemoveVm, {"subject_id" => vm.id, "load_balancer_id" => load_balancer.id}, :destroy_vm_ports_and_update_node
    end
    hop_wait_all_vms_removed
  end

  label def wait_all_vms_removed
    reap(nap: 5) do
      load_balancer.private_subnet.incr_update_firewall_rules
      # The following if statement makes sure that it's OK to not have dns_zone
      # only if it's not in production.
      if (dns_zone = load_balancer.dns_zone) && (Config.production? || dns_zone)
        dns_zone.delete_record(record_name: load_balancer.hostname)
      end
      load_balancer.destroy

      pop "load balancer deleted"
    end
  end

  label def rewrite_dns_records
    decr_rewrite_dns_records

    load_balancer.dns_zone&.delete_record(record_name: load_balancer.hostname)

    load_balancer.vms_to_dns.each do |vm|
      vm_dns_records(vm).each do |type, data|
        load_balancer.dns_zone&.insert_record(
          record_name: load_balancer.hostname,
          type: type,
          ttl: 10,
          data: data
        )
      end
    end

    load_balancer.private_subnet.incr_update_firewall_rules
    load_balancer.incr_update_load_balancer
    hop_wait
  end
end
