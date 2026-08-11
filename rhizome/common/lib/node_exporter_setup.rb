# frozen_string_literal: true

require_relative "util"
require_relative "arch"

class NodeExporterSetup
  VERSION = "1.12.1"
  CHECKSUM = Arch.render(
    x64: "b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63",
    arm64: "ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7",
  )

  def service
    <<~SERVICE
      [Unit]
      Description=Prometheus Node Exporter
      Wants=network-online.target
      After=network-online.target

      [Service]
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectSystem=strict
      ProtectHome=read-only
      ProtectKernelModules=yes
      ProtectKernelTunables=yes
      RestrictRealtime=yes
      RestrictSUIDSGID=yes
      MemoryDenyWriteExecute=yes
      LockPersonality=yes
      Type=simple
      ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
      Restart=always
      User=nobody
      Group=nogroup

      [Install]
      WantedBy=multi-user.target
    SERVICE
  end

  def run
    file_name = "node_exporter-#{VERSION}.linux-#{Arch.render(x64: "amd64", arm64: "arm64")}"
    tarball = "#{file_name}.tar.gz"
    url = "https://github.com/prometheus/node_exporter/releases/download/v#{VERSION}/#{tarball}"

    fail "Invalid SHA-256 digest" unless curl_file(url, tarball) == CHECKSUM

    r "sudo", "tar", "xfz", tarball, "-C", "/usr/local/bin", "--no-same-owner", "--strip-components=1", "#{file_name}/node_exporter"
    r "rm", tarball

    safe_write_to_file("/etc/systemd/system/node_exporter.service", service)

    r "sudo systemctl daemon-reload"
    r "sudo systemctl enable node_exporter"
    r "sudo systemctl start node_exporter"
  end
end
