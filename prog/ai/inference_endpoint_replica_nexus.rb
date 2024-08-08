# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointReplicaNexus < Prog::Base
  subject_is :inference_endpoint_replica

  extend Forwardable
  def_delegators :inference_endpoint_replica, :vm, :inference_endpoint

  semaphore :destroy

  def self.assemble(inference_endpoint_id)
    DB.transaction do
      ubid = InferenceEndpointReplica.generate_ubid

      inference_endpoint = InferenceEndpoint[inference_endpoint_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.inference_endpoint_service_project_id,
        location: inference_endpoint.location,
        name: ubid.to_s,
        size: inference_endpoint.vm_size,
        storage_volumes: inference_endpoint.storage_volumes,
        boot_image: inference_endpoint.boot_image,
        private_subnet_id: inference_endpoint.load_balancer.private_subnet.id,
        enable_ip4: true
      )

      inference_endpoint.load_balancer.add_vm(vm_st.subject)

      replica = InferenceEndpointReplica.create(
        inference_endpoint_id: inference_endpoint_id,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Ai::InferenceEndpointReplicaNexus", label: "start") { _1.id = replica.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the inference endpoint"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "inference_endpoint", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_setup if leaf?
    donate
  end

  label def setup
    case vm.sshable.cmd("common/bin/daemonizer --check setup")
    when "Succeeded"
      hop_pull_image
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo inference_endpoint/bin/setup' setup")
    end

    nap 5
  end

  label def pull_image
    case vm.sshable.cmd("common/bin/daemonizer --check pull_image")
    when "Succeeded"
      vm.sshable.cmd("sudo docker tag vllm/vllm-openai:v0.5.2 vllm:ubi")
      hop_plant_certificates
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo docker pull vllm/vllm-openai:v0.5.2' pull_image")
    end

    nap 5
  end

  label def plant_certificates
    nap 5 if inference_endpoint.server_cert.nil?

    vm.sshable.cmd("sudo mkdir -p /workspace/certs")
    vm.sshable.cmd("sudo tee /workspace/certs/ca.crt > /dev/null", stdin: inference_endpoint.root_cert)
    vm.sshable.cmd("sudo tee /workspace/certs/server.crt > /dev/null", stdin: inference_endpoint.server_cert)
    vm.sshable.cmd("sudo tee /workspace/certs/server.key > /dev/null", stdin: inference_endpoint.server_cert_key)
    # vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
    # vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
    # vm.sshable.cmd("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")

    hop_run_container
  end

  label def run_container
    vm.sshable.cmd("sudo tee .docker_env > /dev/null", stdin: "HF_TOKEN=#{Config.inference_endpoint_hf_token}\nVLLM_API_KEY=#{inference_endpoint.api_key}")
    vm.sshable.cmd(<<~CMD
    sudo docker start vllm || sudo docker run --name vllm \
    --runtime nvidia --gpus all \
    --detach \
    --restart=always \
    -v /workspace:/workspace \
    --env-file .docker_env \
    --env HF_HOME=/workspace/model_cache \
    -p 8000:8000 \
    --ipc=host \
    vllm:ubi \
    --model #{inference_endpoint.model_name} \
    --disable-log-requests \
    --port 8000 \
    --ssl-keyfile /workspace/certs/server.key \
    --ssl-certfile /workspace/certs/server.crt \
    --ssl-ca-certs /workspace/certs/ca.crt
    CMD
                  )
    hop_wait_endpoint_up
  end

  label def wait_endpoint_up
    if inference_endpoint.load_balancer.reload.active_vms.map { _1.id }.include? vm.id
      hop_wait
    end

    nap 5
  end

  label def wait
    nap 30
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    inference_endpoint.load_balancer.evacuate_vm(vm)
    inference_endpoint.load_balancer.remove_vm(vm)
    vm.incr_destroy
    inference_endpoint_replica.destroy

    pop "inference endpoint replica is deleted"
  end
end
