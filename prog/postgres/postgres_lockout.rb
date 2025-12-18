# frozen_string_literal: true

class Prog::Postgres::PostgresLockout < Prog::Base
  subject_is :postgres_server

  label def start
    mechanism = strand.stack.first["mechanism"]

    success = case mechanism
    when "pg_stop"
      lockout_with_pg_stop
    when "hba"
      lockout_with_hba
    when "host_routing"
      lockout_with_host_routing
    else
      false
    end

    pop success ? "lockout_succeeded" : "lockout_failed"
  end

  def lockout_with_pg_stop
    2.times do
      postgres_server.vm.sshable.cmd(
        "sudo pg_ctlcluster :version main stop -m immediate",
        version: postgres_server.version,
        timeout: 2
      )
      Clog.emit("Fenced unresponsive primary by stopping PostgreSQL") { {ubid: postgres_server.ubid} }
      return true
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
    end
    false
  end

  def lockout_with_hba
    2.times do
      postgres_server.vm.sshable.cmd(
        "sudo postgres/bin/lockout-hba :version",
        version: postgres_server.version,
        timeout: 2
      )
      Clog.emit("Fenced unresponsive primary by applying lockout pg_hba.conf") { {ubid: postgres_server.ubid} }
      return true
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
    end
    false
  end

  def lockout_with_host_routing
    return false unless postgres_server.vm.vm_host

    2.times do
      postgres_server.vm.vm_host.sshable.cmd("sudo ip route del :ip4 dev :interface", ip4: postgres_server.vm.ip4, interface: "vmhost#{postgres_server.vm.inhost_name}", timeout: 1)
      postgres_server.vm.vm_host.sshable.cmd("sudo ip -6 route del :net6 dev :interface", net6: postgres_server.vm.ephemeral_net6, interface: "vetho#{postgres_server.vm.inhost_name}", timeout: 1)
      Clog.emit("Fenced unresponsive primary by blocking host routing") { {ubid: postgres_server.ubid} }
      return true
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
    end
    false
  end
end
