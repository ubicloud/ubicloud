# frozen_string_literal: true

require "digest"
require "json"
require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceRouterTargetNexus < Prog::Base
  subject_is :inference_router_target

  extend Forwardable
  def_delegators :inference_router_target, :inference_router, :inference_router_model

  def self.assemble(inference_router_id:, inference_router_model_id:, name:, priority:, inflight_limit:, type: "manual", host: "", enabled: false, config: {}, extra_configs: {}, api_key: SecureRandom.alphanumeric(32))
    DB.transaction do
      target = InferenceRouterTarget.create(
        inference_router_id:,
        inference_router_model_id:,
        name:,
        host:,
        api_key:,
        inflight_limit:,
        priority:,
        config:,
        type:,
        extra_configs:,
        enabled:
      )

      Strand.create(prog: "Ai::InferenceRouterTargetNexus", label: "start") { it.id = target.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the inference router target"
      end
    end
  end

  label def start
    hop_setup if inference_router_target.type == "runpod"
    hop_wait
  end

  label def setup
    register_deadline("wait", 30 * 60)

    pod_config = default_runpod_config
    overlay_config!(pod_config, inference_router_target.config)
    pod_id = runpod_client.create_pod(inference_router_target.ubid, pod_config)
    inference_router_target.update(state: {"pod_id" => pod_id}, host: "#{pod_id}-8080.proxy.runpod.net")
    hop_wait_setup
  end

  label def wait_setup
    pod = runpod_client.get_pod(inference_router_target.state["pod_id"])
    hop_wait unless pod["publicIp"].to_s.empty?
    nap 10
  end

  label def wait
    nap 60 * 60 * 24 * 30
  end

  label def destroy
    decr_destroy

    if (pod_id = inference_router_target.state["pod_id"])
      runpod_client.delete_pod(pod_id)
      inference_router_target.update(state: {})
    end

    inference_router_target.destroy
    pop "inference router target is deleted"
  end

  def runpod_client
    @runpod_client ||= RunpodClient.new
  end

  def default_runpod_config
    {
      "name" => inference_router_target.ubid,
      "cloudType" => "SECURE",
      "computeType" => "GPU",
      "containerDiskInGb" => 50,
      "dockerEntrypoint" => ["bash", "-c"],
      "dockerStartCmd" => [
        <<~CMD.gsub(/\s+/, " ").strip
          apt update;
          DEBIAN_FRONTEND=noninteractive apt-get install openssh-server -y;
          mkdir -p ~/.ssh; cd $_; chmod 700 ~/.ssh;
          echo "$PUBLIC_KEY" >> authorized_keys; chmod 700 authorized_keys;
          service ssh start;
          huggingface-cli download ${HF_MODEL} --repo-type model --local-dir /model;
          vllm serve /model --served-model-name ${HF_MODEL}
          --api-key ${VLLM_API_KEY} --port 8080 --disable-log-requests ${VLLM_PARAMS}
        CMD
      ],
      "env" => {
        "HF_TOKEN" => "{{ RUNPOD_SECRET_HF_TOKEN }}",
        "HF_MODEL" => inference_router_model.model_name,
        "VLLM_API_KEY" => inference_router_target.api_key
      },
      "imageName" => "vllm/vllm-openai:latest",
      "ports" => ["8080/http", "22/tcp"],
      "volumeMountPath" => "/model",
      "volumeInGb" => 50
    }
  end

  def overlay_config!(base_config, overlay_config)
    overlay_config.each do |key, value|
      if base_config[key].is_a?(Hash) && value.is_a?(Hash)
        overlay_config!(base_config[key], value)
      else
        base_config[key] = value
      end
    end

    base_config
  end
end
