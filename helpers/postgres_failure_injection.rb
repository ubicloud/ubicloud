# frozen_string_literal: true

class Clover
  def postgres_inject_failure(pg, failure_type)
    server = pg.representative_server
    raise CloverError.new(400, "InvalidRequest", "No representative server found for this database") unless server

    sshable = server.vm.sshable
    # Audit the attempt before issuing the SSH command so the audit row survives
    # even if the command (or the SSH connection) fails — the request itself
    # is the auditable event.
    audit_log(pg, "inject_failure_#{failure_type}")
    case failure_type
    when "pg_service_stop"
      sshable.cmd("sudo pg_ctlcluster :version main stop -m smart", version: server.version)
    when "os_shutdown"
      begin
        sshable.cmd("sudo shutdown -h now")
      rescue *::Sshable::SSH_CONNECTION_ERRORS, ::Sshable::SshError
        # Expected: SSH connection drops when the machine goes down.
        nil
      end
    else # "pg_restart" — least consequential default; OpenAPI enum constrains failure_type to one of three values
      sshable.cmd("sudo pg_ctlcluster :version main restart", version: server.version)
    end

    204
  end
end
