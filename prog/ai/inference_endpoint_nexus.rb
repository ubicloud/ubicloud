# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointNexus < Prog::Base
  subject_is :inference_endpoint

  extend Forwardable
  def_delegators :inference_endpoint, :replicas, :load_balancer, :private_subnet, :project

  semaphore :destroy

  def self.assemble(project_id:, location:, name:, vm_size:, model_name:, min_replicas: 1, max_replicas: 1)
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
        project_id: project_id, location: location, name: name, vm_size: vm_size, model_name: model_name,
        min_replicas: min_replicas, max_replicas: max_replicas, api_key: SecureRandom.urlsafe_base64,
        load_balancer_id: lb_s.id, private_subnet_id: subnet_s.id
      ) { _1.id = ubid.to_uuid }
      inference_endpoint.associate_with_project(project)

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
    hop_initialize_certificates
  end

  label def initialize_certificates
    inference_endpoint.root_cert, inference_endpoint.root_cert_key = Util.create_root_certificate(common_name: "#{inference_endpoint.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
    inference_endpoint.server_cert, inference_endpoint.server_cert_key = create_certificate
    inference_endpoint.save_changes

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

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(inference_endpoint.root_cert)
    root_cert_key = OpenSSL::PKey::EC.new(inference_endpoint.root_cert_key)

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{load_balancer.hostname}",
      extensions: ["subjectAltName=DNS:#{load_balancer.hostname},DNS:#{replicas.first.vm.ephemeral_net4}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth,clientAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end
end
