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
    end
  end

  def configure_memory_overcommit(strict: false)
    if strict
      total_mem_kb = File.read("/proc/meminfo").match(/MemTotal:\s+(\d+)/)[1].to_i
      # 25% of memory is reserved for hugepages, which do not count towards the
      # commit limit, so only the remaining 75% is available for overcommit.
      non_hugepage_mem_kb = total_mem_kb * 0.75
      overcommit_kbytes = (non_hugepage_mem_kb * 0.8 + 2 * 1048576).round
      safe_write_to_file("/etc/sysctl.d/99-overcommit.conf", "vm.overcommit_memory=2\nvm.overcommit_kbytes=#{overcommit_kbytes}\n")
    else
      r "sudo rm -f /etc/sysctl.d/99-overcommit.conf"
    end

    r "sudo sysctl --system"
  end

  def configure_tcp_keepalive
    safe_write_to_file("/etc/sysctl.d/99-tcp-keepalive.conf", <<~SYSCTL)
      net.ipv4.tcp_keepalive_time=30
      net.ipv4.tcp_keepalive_probes=3
      net.ipv4.tcp_keepalive_intvl=10
    SYSCTL
    r "sudo sysctl --system"
  end

  def setup_data_directory
    r "chown postgres /dat"

    # Below commands are required for idempotency
    r "rm -rf /dat/#{@version}"
    r "rm -rf /etc/postgresql/#{@version}"

    r "echo \"data_directory = '/dat/#{@version}/data'\" | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf"

    safe_write_to_file("/etc/systemd/system/disk-full-check@.service", <<~DISKFULL)
      [Unit]
      Wants=disk-full-check@%i.timer
      Description=Mitigate disk full scenarios

      [Service]
      Type=oneshot
      User=postgres
      ExecStart=/home/ubi/postgres/bin/disk-full-check

      [Install]
      WantedBy=multi-user.target
    DISKFULL

    safe_write_to_file("/etc/systemd/system/disk-full-check@.timer", <<~DISKFULL)
      [Unit]
      Description=Schedule disk full check

      [Timer]
      OnUnitInactiveSec=20sec
      Unit=disk-full-check@%i.service
      Persistent=true

      [Install]
      WantedBy=multiuser.target
    DISKFULL

    r "sudo systemctl enable disk-full-check@#{@version}.timer"
  end

  def create_cluster
    r "pg_createcluster #{@version} main --port=5432 --locale=C.UTF8"
  end
end
