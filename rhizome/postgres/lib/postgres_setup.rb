# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class PostgresSetup
  def initialize(version)
    @version = version
  end

  def install_packages
    r "xargs -a /usr/local/share/postgresql/packages/#{@version}.txt sudo apt-get -y install"
    r "xargs -a /usr/local/share/postgresql/packages/common.txt sudo apt-get -y install"
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
