# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "netaddr"
require "json"
require "openssl"
require "base64"
require "uri"

class ReplicaSetup
  def prep(engine_start_cmd:, replica_ubid:, ssl_crt_path:, ssl_key_path:, gateway_port:, max_requests:)
    write_config_files(replica_ubid, ssl_crt_path, ssl_key_path, gateway_port, max_requests)
    install_systemd_units(engine_start_cmd)
    start_systemd_units
  end

  def start_systemd_units
    r "systemctl enable --now lb-cert-download.timer"
    r "systemctl enable --now inference-engine.service"
  end

  def inference_gateway_service
    "/etc/systemd/system/inference-gateway.service"
  end

  def write(path, s)
    File.open(path, "w") { |f| f.puts(s) }
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

  def lb_cert_download_service
    "/etc/systemd/system/lb-cert-download.service"
  end

  def lb_cert_download_timer
    "/etc/systemd/system/lb-cert-download.timer"
  end

  def write_lb_cert_download_service(s)
    write(lb_cert_download_service, s)
  end

  def write_lb_cert_download_timer(s)
    write(lb_cert_download_timer, s)
  end

  def common_systemd_settings
    <<SETTINGS
# File system and device restrictions
ReadOnlyPaths=/
ReadWritePaths=/ie/workdir
PrivateTmp=yes
PrivateMounts=yes

# User management
SupplementaryGroups=

# Kernel and system protections
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
ProtectControlGroups=yes

# Execution environment restrictions
NoNewPrivileges=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes

# Network restrictions
PrivateNetwork=no

# Additional hardening
KeyringMode=private
SETTINGS
  end

  def write_config_files(replica_ubid, ssl_crt_path, ssl_key_path, gateway_port, max_requests)
    safe_write_to_file("/ie/workdir/inference-gateway.conf", <<CONFIG)
RUST_BACKTRACE=1
RUST_LOG=info
IG_UPGRADE_UDS="/ie/workdir/inference-gateway.upgrade.sock"
IG_CLOVER_UDS="/ie/workdir/inference-gateway.clover.sock"
IG_LISTEN_ADDRESS="0.0.0.0:#{gateway_port}"
IG_MAX_REQUESTS=#{max_requests}
IG_REPLICA_UBID=#{replica_ubid}
IG_SSL_CRT_PATH=#{ssl_crt_path}
IG_SSL_KEY_PATH=#{ssl_key_path}
CONFIG
  end

  def install_systemd_units(engine_start_command)
    write_lb_cert_download_service <<CERT_DOWNLOAD_SERVICE
[Unit]
Description=Download loadbalancer SSL cert service
    
[Service]
ExecStart=/home/ubi/inference_endpoint/bin/download-lb-cert

#{common_systemd_settings}
CERT_DOWNLOAD_SERVICE

    write_lb_cert_download_timer <<CERT_DOWNLOAD_TIMER
[Unit]
Description=Description=Download loadbalancer SSL cert timer

[Timer]
OnActiveSec=1h
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
CERT_DOWNLOAD_TIMER

    write_inference_gateway_service <<GATEWAY
[Unit]
Description=Inference Gateway
After=network.target
StartLimitIntervalSec=0

[Service]
EnvironmentFile=/ie/workdir/inference-gateway.conf
ExecStart=/opt/inference-gateway/inference-gateway
KillSignal=SIGINT
WorkingDirectory=/ie/workdir
User=ie
Group=ie
Restart=always
RestartSec=5
LimitNOFILE=65536

ProtectHome=yes
DynamicUser=yes
PrivateUsers=yes
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @raw-io @reboot @swap
SystemCallArchitectures=native
ProtectSystem=strict
DeviceAllow=
MemoryDenyWriteExecute=true
RemoveIPC=true
UMask=0077

#{common_systemd_settings}
GATEWAY

    write_inference_engine_service <<ENGINE
[Unit]
Description=Inference Engine
After=network.target
After=inference-gateway.service
Requires=inference-gateway.service
StartLimitIntervalSec=0

[Service]
ExecStart=#{engine_start_command}
Environment=HF_HOME=/ie/workdir
Environment=XDG_CACHE_HOME=/ie/workdir/.cache
Environment=XDG_CONFIG_HOME=/ie/workdir/.config
Environment=OUTLINES_CACHE_DIR=/ie/workdir/.outlines
Environment=TRITON_CACHE_DIR=/ie/workdir/.triton
Environment=HOME=/ie/workdir
WorkingDirectory=/ie/workdir
User=ie
Group=ie
Restart=always
RestartSec=5
LimitNOFILE=65536
ProtectHome=yes
DynamicUser=yes
PrivateUsers=yes

#{common_systemd_settings}

[Install]
WantedBy=multi-user.target
ENGINE
    r "systemctl daemon-reload"
  end
end
