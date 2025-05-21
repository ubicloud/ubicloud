# frozen_string_literal: true

class Prog::SetupNodeExporter < Prog::Base
  subject_is :sshable

  label def start
    version = "1.9.1"
    sshable.cmd("sudo host/bin/setup-node-exporter #{version}")
    pop "node exporter was setup"
  end
end
