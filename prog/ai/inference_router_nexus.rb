# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceRouterNexus < Prog::Base
  subject_is :inference_router

  extend Forwardable
  def_delegators :inference_router, :replicas, :load_balancer, :private_subnet, :project

  def self.assemble(project_id:, location_id:, name: "api", vm_size: "standard-2", replica_count: 1)
    fail "No existing location" unless Location[location_id]
    fail "No existing project" unless Project[project_id]

    Validation.validate_name(name)
    fail "Invalid replica count" unless replica_count.is_a?(Integer) && (1..9).cover?(replica_count)
    ubid = InferenceRouter.generate_ubid

    DB.transaction do
      internal_project = Project[Config.inference_endpoint_service_project_id]
      fail "No project configured for inference routers" unless internal_project
      firewall = internal_project.firewalls_dataset.where(location_id:).where(Sequel[:firewall][:name] => "inference-router-firewall").first
      fail "No firewall named 'inference-router-firewall' configured for inference routers in #{Location[location_id].name}" unless firewall
      subnet_s = Prog::Vnet::SubnetNexus.assemble(internal_project.id, name: ubid.to_s, location_id:, firewall_id: firewall.id)

      custom_dns_zone = DnsZone.where(
        project_id: Config.inference_endpoint_service_project_id,
        name: Config.inference_dns_zone
      ).first
      custom_hostname_prefix = name if custom_dns_zone
      lb_s = Prog::Vnet::LoadBalancerNexus.assemble(
        subnet_s.id, name: ubid.to_s, src_port: 443, dst_port: 8443, health_check_endpoint: "/up",
        health_check_protocol: "https", health_check_down_threshold: 3,
        health_check_up_threshold: 1, custom_hostname_prefix: custom_hostname_prefix,
        custom_hostname_dns_zone_id: custom_dns_zone&.id, stack: LoadBalancer::Stack::DUAL,
        cert_enabled: true
      )

      inference_router = InferenceRouter.create(
        project_id:, location_id:, name:, vm_size:, replica_count:, load_balancer_id: lb_s.id, private_subnet_id: subnet_s.id
      ) { it.id = ubid.to_uuid }
      Prog::Ai::InferenceRouterReplicaNexus.assemble(inference_router.id)
      Strand.create_with_id(inference_router.id, prog: "Ai::InferenceRouterNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    reconcile_replicas
    register_deadline("wait", 10 * 60)
    hop_wait_replicas
  end

  label def wait_replicas
    nap 5 if replicas.any? { it.strand.label != "wait" }
    hop_wait
  end

  label def wait
    reconcile_replicas

    nap 60
  end

  label def destroy
    register_deadline(nil, 5 * 60)
    decr_destroy

    replicas.each(&:incr_destroy)
    load_balancer.incr_destroy
    private_subnet.incr_destroy

    hop_self_destroy
  end

  label def self_destroy
    nap 10 if replicas.any?

    inference_router.destroy

    pop "inference router is deleted"
  end

  def reconcile_replicas
    actual_replica_count = replicas.count { !(it.destroy_set? || it.strand.label == "destroy") }
    desired_replica_count = inference_router.replica_count

    if actual_replica_count < desired_replica_count
      (desired_replica_count - actual_replica_count).times do
        Prog::Ai::InferenceRouterReplicaNexus.assemble(inference_router.id)
      end
    elsif actual_replica_count > desired_replica_count
      victims = replicas.select {
                  !(it.destroy_set? || it.strand.label == "destroy")
                }
        .sort_by { |r|
        [(r.strand.label == "wait") ? 1 : 0, r.created_at]
      }.take(actual_replica_count - desired_replica_count)
      victims.each(&:incr_destroy)
    end
  end
end
