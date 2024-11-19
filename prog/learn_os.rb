# frozen_string_literal: true

class Prog::LearnOs < Prog::Base
  subject_is :sshable

  label def start
    ubuntu_version = sshable.cmd("lsb_release --short --release").strip
    pop(os_version: "ubuntu-#{ubuntu_version}")
  end
end
