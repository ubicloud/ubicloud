# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointNexus < Prog::Base
  subject_is :inference_endpoint

  extend Forwardable
  def_delegators :inference_endpoint, :replicas, :load_balancer, :private_subnet, :project

  def self.model_for_id(model_id)
    Option::AI_MODELS.detect { _1["id"] == model_id }
  end

  def self.assemble_with_model(project_id:, location:, name:, model_id:,
    replica_count: 1, is_public: false)
    model = model_for_id(model_id)

    fail "Model with id #{model_id} not found" unless model

    assemble(
      project_id:,
      location:,
      name:,
      boot_image: model["boot_image"],
      vm_size: model["vm_size"],
      storage_volumes: model["storage_volumes"],
      model_name: model["model_name"],
      engine: model["engine"],
      engine_params: model["engine_params"],
      replica_count: replica_count,
      is_public: is_public,
      gpu_count: model["gpu_count"],
      tags: model["tags"]
    )
  end

  def self.assemble(project_id:, location:, boot_image:, name:, vm_size:, storage_volumes:, model_name:,
    engine:, engine_params:, replica_count:, is_public:, gpu_count:, tags:)
    unless Project[project_id]
      fail "No existing project"
    end

    Validation.validate_location(location)
    Validation.validate_name(name)
    Validation.validate_vm_size(vm_size, "x64")
    fail "Invalid replica count" unless replica_count.is_a?(Integer) && (1..9).cover?(replica_count)

    DB.transaction do
      ubid = InferenceEndpoint.generate_ubid
      internal_project = Project[Config.inference_endpoint_service_project_id]
      fail "No project configured for inference endpoints" unless internal_project
      firewall = internal_project.firewalls_dataset.where(location: location).where(Sequel[:firewall][:name] => "inference-endpoint-firewall").first
      fail "No firewall named 'inference-endpoint-firewall' configured for inference endpoints in #{location}" unless firewall
      subnet_s = Prog::Vnet::SubnetNexus.assemble(internal_project.id, name: ubid.to_s, location: location, firewall_id: firewall.id)

      custom_dns_zone = DnsZone.where(project_id: Config.inference_endpoint_service_project_id).where(name: "ai.ubicloud.com").first
      custom_hostname_prefix = if custom_dns_zone
        name + (is_public ? "" : "-#{ubid.to_s[-5...]}")
      end
      lb_s = Prog::Vnet::LoadBalancerNexus.assemble(subnet_s.id, name: ubid.to_s, src_port: 443, dst_port: 8443, health_check_endpoint: "/health", health_check_protocol: "https",
        health_check_down_threshold: 3, health_check_up_threshold: 1, custom_hostname_prefix: custom_hostname_prefix, custom_hostname_dns_zone_id: custom_dns_zone&.id, stack: "ipv4")

      inference_endpoint = InferenceEndpoint.create(
        project_id:, location:, boot_image:, name:, vm_size:, storage_volumes:,
        model_name:, engine:, engine_params:, replica_count:, is_public:,
        load_balancer_id: lb_s.id, private_subnet_id: subnet_s.id, gpu_count:, tags:
      ) { _1.id = ubid.to_uuid }
      Prog::Ai::InferenceEndpointReplicaNexus.assemble(inference_endpoint.id)
      Strand.create(prog: "Ai::InferenceEndpointNexus", label: "start") { _1.id = inference_endpoint.id }
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "self_destroy"].include?(strand.label)
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
    nap 5 if replicas.any? { _1.strand.label != "wait" }
    hop_wait
  end

  label def wait
    reconcile_replicas

    nap 60
  end

  label def destroy
    register_deadline(nil, 5 * 60)
    decr_destroy

    # strand.children.each(&:destroy)
    replicas.each(&:incr_destroy)
    load_balancer.incr_destroy
    private_subnet.incr_destroy

    hop_self_destroy
  end

  label def self_destroy
    nap 10 if replicas.any?

    inference_endpoint.destroy

    pop "inference endpoint is deleted"
  end

  def reconcile_replicas
    actual_replica_count = replicas.count { !(_1.destroy_set? || _1.strand.label == "destroy") }
    desired_replica_count = inference_endpoint.replica_count

    if actual_replica_count < desired_replica_count
      (desired_replica_count - actual_replica_count).times do
        Prog::Ai::InferenceEndpointReplicaNexus.assemble(inference_endpoint.id)
      end
    elsif actual_replica_count > desired_replica_count
      victims = replicas.select {
                  !(_1.destroy_set? || _1.strand.label == "destroy")
                }
        .sort_by { |r|
        [(r.strand.label == "wait") ? 1 : 0, r.created_at]
      }.take(actual_replica_count - desired_replica_count)
      victims.each(&:incr_destroy)
    end
  end
end
