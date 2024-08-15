# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "netaddr"
require "json"
require "openssl"
require "base64"
require "uri"
require_relative "inference_gateway"

class ReplicaSetup
  def prep(inference_gateway_version:, inference_gateway_sha:, inference_gateway_params:, inference_engine:, inference_engine_params:, model:)
    @inference_gateway = InferenceGateway.new(inference_gateway_version, inference_gateway_sha)
    # @inference_gateway.download
    install_systemd_unit(engine_start_command(inference_engine: inference_engine, inference_engine_params: inference_engine_params, model: model))
    start_systemd_unit
  end

  def start_systemd_unit
    r "systemctl start inference-engine.service"
  end

  def inference_gateway_service
    "/etc/systemd/system/inference-gateway.service"
  end

  def write(path, s)
    s += "\n" unless s.end_with?("\n")
    File.write(path, s)
  end

  def write_inference_gateway_service(s)
    write(inference_gateway_service, s)
  end

  def inference_engine_service
    "/etc/systemd/system/inference-engine.service"
  end

  def write_inference_engine_service(s)
    write(inference_engine_service, s)
  end

  def engine_start_command(inference_engine:, inference_engine_params:, model:)
    case inference_engine
    when "vllm"
      "/opt/miniconda/envs/vllm/bin/vllm serve /ie/models/#{model} --served-model-name #{model} --disable-log-requests --host 0.0.0.0 #{inference_engine_params}" # YYY: change to 127.0.0.1
    else
      fail "BUG: unsupported inference engine"
    end
  end

  def install_systemd_unit(engine_start_command)
    #  write_inference_gateway_service <<GATEWAY
    # [Unit]
    # Description=Inference Gateway
    # After=network.target

    # [Service]
    # NetworkNamespacePath=/var/run/netns/#{@vm_name}
    # Type=simple
    # ExecStartPre=/usr/local/sbin/dnsmasq --test
    # ExecStart=/usr/local/sbin/dnsmasq -k -h -C /vm/#{@vm_name}/dnsmasq.conf --log-debug #{tapnames} --user=#{@vm_name} --group=#{@vm_name}
    # ExecReload=/bin/kill -HUP $MAINPID
    # ProtectSystem=strict
    # PrivateDevices=yes
    # PrivateTmp=yes
    # ProtectKernelTunables=yes
    # ProtectControlGroups=yes
    # ProtectHome=yes
    # NoNewPrivileges=yes
    # ReadOnlyPaths=/
    # GATEWAY

    write_inference_engine_service <<ENGINE
[Unit]
Description=Inference Engine
After=network.target
#After=inference-gateway.service
#Requires=inference-gateway.service

[Service]
ExecStart=#{engine_start_command}
Environment=HF_HOME=/ie/workdir
Environment=XDG_CACHE_HOME=/ie/workdir/.cache
Environment=XDG_CONFIG_HOME=/ie/workdir/.config
Environment=OUTLINES_CACHE_DIR=/ie/workdir/.outlines
WorkingDirectory=/ie/workdir
User=ie
Group=ie
Restart=always
ENGINE
    r "systemctl daemon-reload"
  end
end
