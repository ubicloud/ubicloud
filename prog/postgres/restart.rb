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

    hop_restart
  end

  label def restart
    case vm.sshable.d_check("postgres_restart")
    when "Succeeded"
      vm.sshable.d_clean("postgres_restart")
      pop "postgres server is restarted"
    when "Failed"
      vm.sshable.d_clean("postgres_restart")
    when "NotStarted"
      vm.sshable.d_run("postgres_restart", "sudo", "postgres/bin/restart", postgres_server.version)
    end

    nap 5
  end
end
