# frozen_string_literal: true

class Prog::SetupGrafana < Prog::Base
  subject_is :sshable

  def self.assemble(sshable_id, grafana_domain:, certificate_owner_email:)
    grafana_domain = grafana_domain.strip
    certificate_owner_email = certificate_owner_email.strip
    if grafana_domain.empty? || certificate_owner_email.empty?
      fail "grafana_domain and certificate_owner_email should not be empty"
    end
    unless (sshable = Sshable[sshable_id])
      fail "Sshable does not exist"
    end
    Strand.create(prog: "SetupGrafana", label: "start", stack: [{subject_id: sshable.id, domain: grafana_domain, cert_email: certificate_owner_email}])
  end

  def domain
    frame["domain"]
  end

  def cert_email
    frame["cert_email"]
  end

  label def start
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
    else
      Clog.emit("Install grafana failed")
      nap 65536
    end
  end
end
