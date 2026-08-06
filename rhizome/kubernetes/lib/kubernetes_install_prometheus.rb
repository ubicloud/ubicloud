# frozen_string_literal: true

require_relative "../../common/lib/util"

class KubernetesInstallPrometheus
  VERSION = "3.13.2"
  CHECKSUM = "0e8c4d46101bd025ea8265e377d2caabc57f488fc1be1c367f37db69ea41be6f"

  # metrics-collector federates every scrape out to VictoriaMetrics, so the
  # local blocks only need to cover collector downtime. MemoryMax keeps a
  # scrape of the apiserver from squeezing etcd on a control plane node.
  SERVICE = <<~SERVICE
    [Unit]
    Description=Prometheus
    Wants=network-online.target
    After=network-online.target

    [Service]
    NoNewPrivileges=yes
    PrivateTmp=yes
    ProtectSystem=strict
    ProtectHome=read-only
    ReadWritePaths=/var/lib/prometheus
    ProtectKernelModules=yes
    ProtectKernelTunables=yes
    RestrictRealtime=yes
    RestrictSUIDSGID=yes
    MemoryDenyWriteExecute=yes
    LockPersonality=yes
    MemoryMax=1G
    Type=simple
    ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=2h --storage.tsdb.wal-compression --web.listen-address=127.0.0.1:9090
    ExecReload=/bin/kill -HUP $MAINPID
    Restart=always
    User=prometheus
    Group=prometheus

    [Install]
    WantedBy=multi-user.target
  SERVICE

  def run
    file_name = "prometheus-#{VERSION}.linux-amd64"
    tarball = "#{file_name}.tar.gz"
    url = "https://github.com/prometheus/prometheus/releases/download/v#{VERSION}/#{tarball}"

    fail "Invalid SHA-256 digest" unless curl_file(url, tarball) == CHECKSUM

    r "tar", "xfz", tarball, "-C", "/usr/local/bin", "--no-same-owner", "--strip-components=1", "#{file_name}/prometheus"
    r "rm", tarball

    r "groupadd -f --system prometheus"
    r "useradd --no-create-home --system -g prometheus prometheus", expect: [0, 9] # 9 is "already exists"
    r "mkdir -p /etc/prometheus /var/lib/prometheus"
    r "chown prometheus:prometheus /var/lib/prometheus"

    safe_write_to_file("/etc/systemd/system/prometheus.service", SERVICE)

    r "systemctl daemon-reload"
  end
end
