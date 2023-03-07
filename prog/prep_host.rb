# frozen_string_literal: true

class Prog::PrepHost < Prog::Base
  def sshable
    @sshable ||= Sshable[frame["vmhost_id"]]
  end

  def start
    sshable.cmd("sudo bin/prep_host.rb")
    pop "host prepared"
  end
end
