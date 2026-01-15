# frozen_string_literal: true

class Prog::SetupNodeExporter < Prog::Base
  subject_is :sshable

  label def start
    sshable.cmd("sudo host/bin/setup-node-exporter 1.9.1")
    pop "node exporter was setup"
  end
end
