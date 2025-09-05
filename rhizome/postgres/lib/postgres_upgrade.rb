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

  def disable_archive_mode
    r "echo 'archive_mode = off' | sudo tee /etc/postgresql/#{@prev_version}/main/conf.d/100-upgrade.conf"
    r "sudo pg_ctlcluster #{@prev_version} main restart"
  end

  def promote(version)
    if r("sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null || echo 't'").strip == "f"
      @logger.info("Server is already promoted (not in recovery mode)")
      return
    end

    r "sudo pg_ctlcluster promote #{version} main", expect: [0, 1]
  end

  def disable_previous_version
    r "sudo systemctl disable --now postgresql@#{@prev_version}-main"
  end

  def initialize_new_version
    pg_setup = PostgresSetup.new(@version, Logger.new($stdout))
    pg_setup.setup_packages
    pg_setup.setup_data_directory
    pg_setup.create_cluster
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
    Dir.glob("/dat/upgrade/#{@version}/*.sql") do |script|
      r "sudo -u postgres psql -v 'ON_ERROR_STOP=1' -f #{script.shellescape}"
    end
  end

  def run_post_upgrade_extension_update
    # TODO: List any steps required for updating specific extensions.
  end

  def upgrade
    puts "Creating upgrade directory"
    create_upgrade_dir
    puts "Disabling archive mode"
    disable_archive_mode
    puts "Waiting for postgres to start"
    wait_for_postgres_to_start
    puts "Promoting previous version"
    promote @prev_version
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
    puts "Waiting for postgres to start"
    wait_for_postgres_to_start
    puts "Running post upgrade scripts"
    run_post_upgrade_scripts
    puts "Running post upgrade extension update"
    run_post_upgrade_extension_update
  end

  def run_query(query)
    r "sudo -u postgres psql -v 'ON_ERROR_STOP=1' -d template1", stdin: query
  end
end
