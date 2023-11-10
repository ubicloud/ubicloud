# frozen_string_literal: true

class Prog::SetupSysstat < Prog::Base
  subject_is :sshable

  label def start
    sshable.cmd("sudo host/bin/setup-sysstat")
    pop "Sysstat was setup"
  end
end
