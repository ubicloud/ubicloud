# frozen_string_literal: true

class Prog::Vm::PrepHost < Prog::Base
  subject_is :sshable

  label def start
    sshable.cmd("sudo bin/prep_host.rb")
    pop "host prepared"
  end
end
