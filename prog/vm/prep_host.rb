# frozen_string_literal: true

class Prog::Vm::PrepHost < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    sshable.cmd("sudo host/bin/prep_host.rb :ubid :rack_env", ubid: vm_host.ubid, rack_env: Config.rack_env)
    pop "host prepared"
  end
end
