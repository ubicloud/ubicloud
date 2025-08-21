# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class PostgresUpgrade
  def initialize(version, logger)
    @version = Integer(version)
    @prev_version = @version - 1
    @logger = logger
  end

  def disable_previous_version
    r "sudo systemctl disable --now postgresql@#{@prev_version}-main"
  end

  def initialize_new_version
    r "sudo postgres/bin/initialize-empty-database #{@version}"
  end

  def enable_new_version
    r "sudo systemctl enable --now postgresql@#{@version}-main"
  end

  def run_check
    r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/pg_upgrade --old-bindir /usr/lib/postgresql/#{@prev_version}/bin --old-datadir /etc/postgresql/#{@prev_version}/main/ --new-bindir /usr/lib/postgresql/#{@version}/bin --new-datadir /etc/postgresql/#{@version}/main/ --check"
  end

  def run_pg_upgrade
    r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/pg_upgrade --old-bindir /usr/lib/postgresql/#{@prev_version}/bin --old-datadir /etc/postgresql/#{@prev_version}/main/ --new-bindir /usr/lib/postgresql/#{@version}/bin --new-datadir /etc/postgresql/#{@version}/main/ --link"
  end

  def run_post_upgrade_scripts

  end

  def run_post_upgrade_extension_update
  end

  def upgrade
    puts "Disabling previous version"
    disable_previous_version
    puts "Initializing new version"
    initialize_new_version
    puts "Enabling new version"
    enable_new_version
    puts "Running check"
    run_check
    puts "Running pg upgrade"
    run_pg_upgrade
    puts "Running post upgrade scripts"
    run_post_upgrade_scripts
    puts "Running post upgrade extension update"
    run_post_upgrade_extension_update
  end

  def run_query(query)
    r "sudo -u postgres psql -v 'ON_ERROR_STOP=1' -d template1", stdin: query
  end
end
