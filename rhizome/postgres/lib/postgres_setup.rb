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
