# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "postgres_setup"
require_relative "postgres_extensions"
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

  def disable_archiving(version, reload: false)
    r "echo 'archive_mode = on\narchive_command = false' | sudo tee /etc/postgresql/#{version}/main/conf.d/100-upgrade.conf"
    r "sudo pg_ctlcluster #{version} main reload" if reload
  end

  def remove_walg_credentials
    r "sudo rm -f /etc/postgresql/wal-g.env"
    r "sudo systemctl stop wal-g", expect: [0, 1, 4, 5]
  end

  def promote(version)
    if r("sudo -u postgres psql -t -c 'SELECT pg_catalog.pg_is_in_recovery();' 2>/dev/null || echo 't'").strip == "f"
      @logger.info("Server is already promoted (not in recovery mode)")
      return
    end

    result = r("sudo -u postgres psql -t -c \"SELECT pg_promote(true, 300)\"").strip
    fail "pg_promote returned #{result.inspect}" unless result == "t"
  end

  def disable_previous_version
    r "sudo systemctl disable --now postgresql@#{@prev_version}-main"
  end

  def initialize_new_version
    pg_setup = PostgresSetup.new(@version)
    pg_setup.install_packages
    disable_previous_version
    pg_setup.setup_data_directory
    pg_setup.create_cluster
  end

  # pg_upgrade needs user config so settings like wal_level & max_replication_slots are there for preserved logical slots
  def apply_user_config(user_config)
    contents = user_config.map { |k, v| "#{k} = #{v}" }.join("\n")
    safe_write_to_file("/etc/postgresql/#{@version}/main/conf.d/099-user.conf", contents)
  end

  def run_check
    run_pg_upgrade_cmd("--check")
  end

  def run_pg_upgrade
    run_pg_upgrade_cmd("--link")
  end

  def enable_new_version
    r "sudo systemctl enable --now postgresql@#{@version}-main"
  end

  def wait_for_postgres_to_start
    deadline = Time.now + 60
    loop do
      r "sudo -u postgres pg_isready"
      break
    rescue
      raise "Postgres failed to start" if Time.now > deadline

      sleep 1
    end
  end

  def run_post_upgrade_scripts
    Dir.glob("/dat/upgrade/#{@version}/*.sql") do |script|
      r "sudo -u postgres psql -v 'ON_ERROR_STOP=1' -f #{script.shellescape}"
    end
  end

  def run_post_upgrade_extension_update
    databases = r("sudo -u postgres psql -t -c 'SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = false;'").split("\n").map(&:strip)

    scripts = EXTENSION_UPGRADE_SCRIPTS[@version]
    scripts.each do |extension, script|
      @logger.info("Running post upgrade extension update for #{extension}")
      databases.each do |database|
        installed = r("sudo -u postgres psql -d #{database.shellescape} -v 'ON_ERROR_STOP=1' -t", stdin: "SELECT 1 FROM pg_catalog.pg_extension WHERE extname = '#{extension.gsub("'", "''")}'").strip
        if installed == "1"
          @logger.info("Running post upgrade extension update for #{extension} on database #{database}")
          r("sudo -u postgres psql -d #{database.shellescape} -v 'ON_ERROR_STOP=1'", stdin: script)
        end
      end
    end
  end

  def upgrade(configure_hash)
    @logger.info("Creating upgrade directory")
    create_upgrade_dir
    @logger.info("Removing WAL-G credentials")
    remove_walg_credentials
    @logger.info("Disabling archiving for previous version")
    disable_archiving(@prev_version, reload: true)
    @logger.info("Waiting for postgres to start")
    wait_for_postgres_to_start
    @logger.info("Promoting previous version")
    promote @prev_version
    @logger.info("Initializing new version")
    initialize_new_version
    @logger.info("Applying user config to new cluster")
    apply_user_config(configure_hash["user_config"])
    @logger.info("Running check")
    run_check
    @logger.info("Running pg upgrade")
    run_pg_upgrade
    @logger.info("Disabling archiving for new version")
    disable_archiving(@version)
    @logger.info("Enabling new version")
    enable_new_version
    @logger.info("Waiting for postgres to start")
    wait_for_postgres_to_start
    @logger.info("Running post upgrade scripts")
    run_post_upgrade_scripts
    @logger.info("Running post upgrade extension update")
    run_post_upgrade_extension_update
  end

  def run_pg_upgrade_cmd(arg)
    Dir.chdir("/dat/upgrade/#{@version}") do
      r pg_upgrade_cmdline(arg)
    end
  end

  def pg_upgrade_cmdline(arg)
    "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/pg_upgrade --old-bindir /usr/lib/postgresql/#{@prev_version}/bin --old-datadir /etc/postgresql/#{@prev_version}/main/ --new-bindir /usr/lib/postgresql/#{@version}/bin --new-datadir /etc/postgresql/#{@version}/main/ #{arg}"
  end
end
