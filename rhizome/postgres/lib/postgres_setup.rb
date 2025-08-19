# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class PostgresSetup
  def initialize(version, logger)
    @version = version
    @logger = logger
  end

  def setup
    r "sudo apt-get -y install $(cat /usr/local/share/postgresql/packages/#{@version}.txt | tr \"\n\" \"\")"
    r "sudo apt-get -y install $(cat /usr/local/share/postgresql/packages/common.txt | tr \"\n\" \"\")"
  end

  def teardown
    r "sudo apt-get -y remove $(cat /usr/local/share/postgresql/packages/#{@version}.txt | tr \"\n\" \"\")"
  end
end
