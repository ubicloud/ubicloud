# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "postgres_setup"
require "logger"
require "timeout"

class PostgresUpgrade
  def initialize(version, logger)
    @version = Integer(version)
    @prev_version = @version - 1
    @logger = logger
  end

  def create_upgrade_dir
    r "sudo mkdir -p /dat/upgrade/#{@version}"
    r "sudo chown postgres:postgres /dat/upgrade/#{@version}"
  end

  def promote_previous_version
    # Try to promote, ignore failure if output in case server is already promoted.
    r "sudo pg_ctlcluster promote #{@prev_version} main", expect: [0, 1]
  end

  def disable_previous_version
    r "sudo systemctl disable --now postgresql@#{@prev_version}-main"
  end

  def initialize_new_version
    # TODO: Move these to a separate setup step.
    r "chown postgres /dat"
    PostgresSetup.new(@version, Logger.new($stdout)).setup
    r "rm -rf /dat/#{@version}"
    r "rm -rf /etc/postgresql/#{@version}"
    r "echo \"data_directory = '/dat/#{@version}/data'\" | sudo tee /etc/postgresql-common/createcluster.d/data-dir.conf"
    r "pg_createcluster #{@version} main --port=5432 --start --locale=C.UTF8"
  end

  def stop_new_version
    r "sudo systemctl stop postgresql@#{@version}-main"
  end

  def run_check
    Dir.chdir("/dat/upgrade/#{@version}") do
      r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/pg_upgrade --old-bindir /usr/lib/postgresql/#{@prev_version}/bin --old-datadir /etc/postgresql/#{@prev_version}/main/ --new-bindir /usr/lib/postgresql/#{@version}/bin --new-datadir /etc/postgresql/#{@version}/main/ --check"
    end
  end

  def run_pg_upgrade
    Dir.chdir("/dat/upgrade/#{@version}") do
      r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/pg_upgrade --old-bindir /usr/lib/postgresql/#{@prev_version}/bin --old-datadir /etc/postgresql/#{@prev_version}/main/ --new-bindir /usr/lib/postgresql/#{@version}/bin --new-datadir /etc/postgresql/#{@version}/main/ --link"
    end
  end

  def enable_new_version
    r "sudo systemctl enable --now postgresql@#{@version}-main"
  end

  def wait_for_postgres_to_start
    Timeout.timeout(60) do
      loop do
        r "sudo -u postgres pg_isready"
        break
      rescue
        sleep 1
      end
    end
  end

  def run_post_upgrade_scripts

  end

  def run_post_upgrade_extension_update
  end

  def upgrade
    puts "Creating upgrade directory"
    create_upgrade_dir
    puts "Promoting previous version"
    promote_previous_version
    puts "Disabling previous version"
    disable_previous_version
    puts "Initializing new version"
    initialize_new_version
    puts "Stop new version"
    stop_new_version
    puts "Running check"
    run_check
    puts "Running pg upgrade"
    run_pg_upgrade
    puts "Enabling new version"
    enable_new_version
    puts "Running post upgrade scripts"
    run_post_upgrade_scripts
    puts "Running post upgrade extension update"
    run_post_upgrade_extension_update
  end

  def run_query(query)
    r "sudo -u postgres psql -v 'ON_ERROR_STOP=1' -d template1", stdin: query
  end
end
