# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointNexus < Prog::Base
  subject_is :inference_endpoint

  extend Forwardable
  def_delegators :inference_endpoint, :replicas, :load_balancer, :private_subnet, :project

  semaphore :destroy

  def self.assemble_with_model(project_id:, location:, name:, model_id:,
    min_replicas: 1, max_replicas: 1, public: false)
    model = Option::MODELS.detect { _1["id"] == model_id }

    fail "Model with id #{model_id} not found" unless model

    assemble(
      project_id: project_id,
      location: location,
      name: name,
      boot_image: model["boot_image"],
      vm_size: model["vm_size"],
      storage_volumes: model["storage_volumes"],
      model_name: model["model_name"],
      engine: model["engine"],
      engine_params: model["engine_params"],
      min_replicas: min_replicas,
      max_replicas: max_replicas,
      public: public
    )
  end

  def self.assemble(project_id:, location:, boot_image:, name:, vm_size:, storage_volumes:, model_name:,
    engine: "vllm", engine_params: "", min_replicas: 1, max_replicas: 1, public: false)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_location(location)
    Validation.validate_name(name)
    Validation.validate_vm_size(vm_size)

    DB.transaction do
      ubid = InferenceEndpoint.generate_ubid
      subnet_s = Prog::Vnet::SubnetNexus.assemble(Config.inference_endpoint_service_project_id, name: ubid.to_s, location: location, firewall_id: Config.inference_endpoint_service_firewall_id)
      lb_s = Prog::Vnet::LoadBalancerNexus.assemble(subnet_s.id, name: name, src_port: 8000, dst_port: 8000, health_check_endpoint: "/health")

      inference_endpoint = InferenceEndpoint.create(
        project_id: project_id, location: location, boot_image: boot_image, name: name, vm_size: vm_size, storage_volumes: storage_volumes,
        model_name: model_name, engine: engine, engine_params: engine_params, min_replicas: min_replicas, max_replicas: max_replicas, public: public,
        load_balancer_id: lb_s.id, private_subnet_id: subnet_s.id
      ) { _1.id = ubid.to_uuid }
      inference_endpoint.associate_with_project(project)
      ApiKeyPair.create_with_id(owner_id: inference_endpoint.id, owner_table: "inference_endpoint") unless public

      min_replicas.times do
        Prog::Ai::InferenceEndpointReplicaNexus.assemble(inference_endpoint.id)
      end

      Strand.create(prog: "Ai::InferenceEndpointNexus", label: "start") { _1.id = inference_endpoint.id }
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
    hop_wait_replicas
  end

  label def wait_replicas
    nap 5 if replicas.any? { _1.strand.label != "wait" }
    hop_wait
  end

  label def wait
    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)
    decr_destroy

    strand.children.each { _1.destroy }
    replicas.each(&:incr_destroy)
    load_balancer.incr_destroy
    private_subnet.incr_destroy

    hop_self_destroy
  end

  label def self_destroy
    inference_endpoint.dissociate_with_project(project)
    inference_endpoint.destroy

    pop "inference endpoint is deleted"
  end
end
