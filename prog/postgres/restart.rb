# frozen_string_literal: true

class Prog::Postgres::Restart < Prog::Base
  subject_is :postgres_server

  def vm
    @vm ||= postgres_server.vm
  end

  label def start
    register_deadline(nil, 5 * 60)
    if postgres_server.configure_set?
      # Pop so that the parent can handle the configure
      pop "restart deferred due to pending configure"
    end

    vm.sshable.cmd("sudo postgres/bin/restart :version", version: postgres_server.version)
    vm.sshable.cmd("sudo systemctl restart 'pgbouncer@*.service'")
    vm.sshable.cmd("sudo systemctl restart postgres-metrics.timer")
    pop "postgres server is restarted"
  end
end
