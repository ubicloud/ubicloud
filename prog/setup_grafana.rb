# frozen_string_literal: true

class Prog::SetupGrafana < Prog::Base
  subject_is :sshable

  def domain
    frame["domain"].strip
  end

  def cert_email
    frame["cert_email"].strip
  end

  label def start
    if domain.empty? || cert_email.empty?
      fail "domain and cert_email should not be empty"
    end
    hop_install_rhizome
  end

  label def install_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "host", "subject_id" => sshable.id, "user" => sshable.unix_user}
    hop_wait_for_rhizome
  end

  label def wait_for_rhizome
    reap
    hop_install_grafana if leaf?
    donate
  end

  label def install_grafana
    case sshable.d_check("install_grafana")
    when "Succeeded"
      sshable.d_clean("install_grafana")
      pop "grafana was setup"
    when "NotStarted"
      sshable.d_run("install_grafana", "sudo", "host/bin/setup-grafana", domain, cert_email)
      nap 10
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("Install grafana failed")
      nap 65536
    end
    nap 65536
  end
end
