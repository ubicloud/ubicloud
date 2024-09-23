# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "netaddr"
require "json"
require "openssl"
require "base64"
require "uri"

class ReplicaSetup
  def prep(inference_engine:, inference_engine_params:, model:, replica_ubid:, ssl_crt_path:, ssl_key_path:, use_self_signed_cert:, gateway_port:)
    engine_start_cmd = engine_start_command(inference_engine: inference_engine, inference_engine_params: inference_engine_params, model: model)
    write_config_files(replica_ubid, ssl_crt_path, ssl_key_path, gateway_port)
    install_systemd_units(engine_start_cmd, use_self_signed_cert)
    start_systemd_units
  end

  def start_systemd_units
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
      "/opt/miniconda/envs/vllm/bin/vllm serve /ie/models/model --served-model-name #{model} --disable-log-requests --host 127.0.0.1 #{inference_engine_params}"
    else
      fail "BUG: unsupported inference engine"
    end
  end

  def write_config_files(replica_ubid, ssl_crt_path, ssl_key_path, gateway_port)
    safe_write_to_file("/ie/workdir/inference-gateway.conf", <<CONFIG)
RUST_BACKTRACE=1
RUST_LOG=info
IG_DAEMON=true
IG_LOG="/ie/workdir/inference-gateway.log"
IG_PID_FILE="/ie/workdir/inference-gateway.pid"
IG_UPGRADE_UDS="/ie/workdir/inference-gateway.upgrade.sock"
IG_CLOVER_UDS="/ie/workdir/inference-gateway.clover.sock"
IG_LISTEN_ADDRESS="0.0.0.0:#{gateway_port}"
IG_REPLICA_UBID=#{replica_ubid}
IG_SSL_CRT_PATH=#{ssl_crt_path}
IG_SSL_KEY_PATH=#{ssl_key_path}
CONFIG
  end

  def install_systemd_units(engine_start_command, use_self_signed_cert)
    write_inference_gateway_service <<GATEWAY
[Unit]
Description=Inference Gateway
After=network.target

[Service]
EnvironmentFile=/ie/workdir/inference-gateway.conf
Type=forking
PIDFile=/ie/workdir/inference-gateway.pid
ExecStartPre=/home/ubi/inference_endpoint/bin/get-lb-cert #{use_self_signed_cert ? "self-signed" : "load-balancer"}
ExecStart=/opt/inference-gateway/inference-gateway
LimitNOFILE=65536
GATEWAY

    write_inference_engine_service <<ENGINE
[Unit]
Description=Inference Engine
After=network.target
After=inference-gateway.service
Requires=inference-gateway.service

[Service]
ExecStart=#{engine_start_command}
Environment=HF_HOME=/ie/workdir
Environment=XDG_CACHE_HOME=/ie/workdir/.cache
Environment=XDG_CONFIG_HOME=/ie/workdir/.config
Environment=OUTLINES_CACHE_DIR=/ie/workdir/.outlines
Environment=TRITON_CACHE_DIR=/ie/workdir/.triton
WorkingDirectory=/ie/workdir
User=ie
Group=ie
Restart=always
LimitNOFILE=65536
ENGINE
    r "systemctl daemon-reload"
  end
end
