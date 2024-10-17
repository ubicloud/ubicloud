# frozen_string_literal: true

require_relative "../base"

class Prog::Vm::PrepHost < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    sshable.cmd("sudo host/bin/prep_host.rb #{vm_host.ubid.shellescape} #{Config.rack_env.shellescape}")
    pop "host prepared"
  end
end
