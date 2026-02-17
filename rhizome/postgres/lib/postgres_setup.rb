# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class PostgresSetup
  def initialize(version)
    @version = version
  end

  def install_packages
    # Check if the packages exist in the cache, if so, install them.
    if File.exist?("/var/cache/postgresql-packages/#{@version}")
      r "sudo install-postgresql-packages #{@version}"
    elsif !File.exist?("/usr/lib/postgresql/#{@version}/bin/pg_config")
      install_from_apt
    end
  end

  def install_from_apt
    r "sudo apt-get update -qq"
    r "sudo apt-get install -y -qq postgresql-common"
    r "sudo mkdir -p /etc/postgresql-common/createcluster.d"

    unless File.exist?("/usr/share/keyrings/pgdg.gpg")
      r "wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/pgdg.gpg"
      r "echo 'deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt #{`lsb_release -cs`.strip}-pgdg main' | sudo tee /etc/apt/sources.list.d/pgdg.list"
      r "sudo apt-get update -qq"
    end

    # Configure PostgreSQL to not auto-create clusters and use data checksums
    r "echo \"create_main_cluster = 'off'\" | sudo tee -a /etc/postgresql-common/createcluster.conf"
    r "echo \"initdb_options = '--data-checksums'\" | sudo tee -a /etc/postgresql-common/createcluster.conf"
    r "echo \"include_dir = '/etc/postgresql-common/createcluster.d'\" | sudo tee -a /etc/postgresql-common/createcluster.conf"

    r "sudo apt-get install -y -qq postgresql-#{@version} postgresql-#{@version}-cron pgbouncer"

    # Create prerequisite users and groups
    r "sudo adduser --disabled-password --gecos '' prometheus" unless system("id prometheus > /dev/null 2>&1")
    r "sudo adduser --disabled-password --gecos '' ubi_monitoring" unless system("id ubi_monitoring > /dev/null 2>&1")
    r "sudo groupadd cert_readers" unless system("getent group cert_readers > /dev/null 2>&1")
    r "sudo usermod --append --groups cert_readers postgres"
    r "sudo usermod --append --groups cert_readers prometheus"

    # Install WAL-G binary
    unless File.exist?("/usr/bin/wal-g")
      r "sudo wget -q -O /usr/bin/wal-g https://github.com/wal-g/wal-g/releases/download/v3.0.8/wal-g-pg-24.04-amd64"
      r "sudo chmod +x /usr/bin/wal-g"
    end

    # Install monitoring binaries and systemd services
    install_monitoring_tools
  end

  def install_monitoring_tools
    arch = (`uname -m`.strip == "aarch64") ? "arm64" : "amd64"

    [
      {name: "prometheus", url: "https://github.com/prometheus/prometheus/releases/download/v2.53.0/prometheus-2.53.0.linux-#{arch}.tar.gz", bin_dir: "prometheus-2.53.0.linux-#{arch}", owner: "prometheus:prometheus"},
      {name: "node_exporter", url: "https://github.com/prometheus/node_exporter/releases/download/v1.8.1/node_exporter-1.8.1.linux-#{arch}.tar.gz", bin_dir: "node_exporter-1.8.1.linux-#{arch}", owner: "prometheus:prometheus"},
      {name: "postgres_exporter", url: "https://github.com/prometheus-community/postgres_exporter/releases/download/v0.15.0/postgres_exporter-0.15.0.linux-#{arch}.tar.gz", bin_dir: "postgres_exporter-0.15.0.linux-#{arch}", owner: "ubi_monitoring:ubi_monitoring"}
    ].each do |tool|
      next if File.exist?("/usr/bin/#{tool[:name]}")
      r "wget -q -O /tmp/#{tool[:name]}.tar.gz #{tool[:url]}"
      r "tar -xzf /tmp/#{tool[:name]}.tar.gz -C /tmp"
      r "sudo cp /tmp/#{tool[:bin_dir]}/#{tool[:name]} /usr/bin/#{tool[:name]}"
      r "sudo chown #{tool[:owner]} /usr/bin/#{tool[:name]} && sudo chmod 100 /usr/bin/#{tool[:name]}"
      r "rm -rf /tmp/#{tool[:name]}*"
    end

    r "sudo mkdir -p /usr/local/share/postgresql"
    r "sudo touch /usr/local/share/postgresql/postgres_exporter_queries.yaml" unless File.exist?("/usr/local/share/postgresql/postgres_exporter_queries.yaml")

    install_systemd_services
  end

  def install_systemd_services
    services = {
      "wal-g" => "[Unit]\nDescription=WAL-G Daemon\nAfter=network-online.target\n\n[Service]\nUser=postgres\nGroup=postgres\nType=simple\nEnvironmentFile=/etc/postgresql/wal-g.env\nExecStart=/usr/bin/wal-g daemon /tmp/wal-g\nRestart=always\n\n[Install]\nWantedBy=multi-user.target",
      "prometheus" => "[Unit]\nDescription=Prometheus\nAfter=network-online.target\n\n[Service]\nUser=prometheus\nGroup=prometheus\nType=simple\nExecStart=/usr/bin/prometheus --config.file=/home/prometheus/prometheus.yml --web.config.file=/home/prometheus/web-config.yml --storage.tsdb.path=/home/prometheus/data --storage.tsdb.retention.size=1GB\nRestart=always\n\n[Install]\nWantedBy=multi-user.target",
      "node_exporter" => "[Unit]\nDescription=Node Exporter\nAfter=network-online.target\n\n[Service]\nUser=prometheus\nGroup=prometheus\nType=simple\nExecStart=/usr/bin/node_exporter --collector.disable-defaults --collector.cpu --collector.diskstats --collector.filesystem --collector.loadavg --collector.meminfo --collector.netdev --collector.uname --web.disable-exporter-metrics\nRestart=always\n\n[Install]\nWantedBy=multi-user.target",
      "postgres_exporter" => "[Unit]\nDescription=PostgreSQL Exporter\nAfter=network-online.target\n\n[Service]\nUser=ubi_monitoring\nGroup=ubi_monitoring\nType=simple\nEnvironment=DATA_SOURCE_NAME=\"host=/var/run/postgresql dbname=postgres\"\nExecStart=/usr/bin/postgres_exporter --disable-default-metrics --no-collector.stat_bgwriter --no-collector.stat_database --no-collector.locks --no-collector.database --extend.query-path=/usr/local/share/postgresql/postgres_exporter_queries.yaml\nRestart=always\n\n[Install]\nWantedBy=multi-user.target"
    }

    services.each do |name, content|
      path = "/etc/systemd/system/#{name}.service"
      next if File.exist?(path)
      File.write("/tmp/#{name}.service", content)
      r "sudo cp /tmp/#{name}.service #{path}"
    end

    r "sudo systemctl daemon-reload"
  end

  def configure_memory_overcommit
    # r "sudo sysctl -w vm.overcommit_memory=2"
    # r "echo 'vm.overcommit_memory=2' | sudo tee -a /etc/sysctl.conf"

    # r "sudo sysctl -w vm.overcommit_ratio=150"
    # r "echo 'vm.overcommit_ratio=150' | sudo tee -a /etc/sysctl.conf"
  end

  def setup_data_directory
    r "chown postgres /dat"

    # Below commands are required for idempotency
    r "rm -rf /dat/#{@version}"
    r "rm -rf /etc/postgresql/#{@version}"

    r "echo \"data_directory = '/dat/#{@version}/data'\" | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf"
  end

  def create_cluster
    r "pg_createcluster #{@version} main --port=5432 --start --locale=C.UTF8"
  end
end
