# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "ember_config"
require "io/wait"
require "socket"

class GuestPostgresManager
  class Error < StandardError; end

  PORT = 5432

  PROTOCOL_VERSION = 196_608

  def self.install
    r("apt-get", "update")
    r("apt-get", "-y", "install", "postgresql-client")
  end

  def initialize(slot)
    @slot = slot
  end

  def ready?
    socket = Socket.tcp(@slot.public_ip6, PORT, @slot.link_host_ip6, nil, connect_timeout: 0.2)
    body = "user\0postgres\0database\0postgres\0\0"
    socket.write([8 + body.bytesize, PROTOCOL_VERSION].pack("NN") + body)
    return false unless socket.wait_readable(1)

    case socket.read(1)
    when "R"
      true
    when "E"
      !socket.read_nonblock(4096, exception: false).to_s.include?("57P03")
    else
      false
    end
  rescue SystemCallError, IOError
    false
  ensure
    socket&.close
  end

  def wait_ready(timeout:)
    deadline = monotonic + timeout
    until ready?
      fail Error, "PostgreSQL did not accept connections within #{timeout}s" if monotonic > deadline
      sleep 0.01
    end
  end

  def configure(payload)
    superuser_password = payload["superuser_password"]
    database = payload["database"]
    sql = +""
    sql << "ALTER ROLE postgres PASSWORD #{literal(superuser_password)};\n" if superuser_password
    if database && database != "postgres"
      sql << "SELECT 'CREATE DATABASE ' || quote_ident(#{literal(database)}) " \
             "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = #{literal(database)}) \\gexec\n"
    end
    run_sql(sql) unless sql.empty?
  end

  private

  def run_sql(sql)
    r("ip", "netns", "exec", @slot.netns, "env", "PGCONNECT_TIMEOUT=10",
      "psql", "-X", "-q", "-w", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=terse",
      "-h", EmberConfig::GUEST_IP6, "-p", PORT.to_s, "-U", "postgres", "-d", "postgres",
      "-f", "-", stdin: sql)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def literal(value)
    value = value.to_s
    fail Error, "NUL in a SQL literal" if value.include?("\0")
    "E'#{value.gsub("\\", "\\\\\\\\").gsub("'", "''")}'"
  end
end
