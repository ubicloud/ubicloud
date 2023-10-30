# frozen_string_literal: true

class Prog::LearnArch < Prog::Base
  subject_is :sshable

  label def start
    arch = sshable.cmd("common/bin/arch").strip
    fail "BUG: unexpected CPU architecture" unless ["arm64", "x64"].include?(arch)
    pop(arch: arch)
  end
end
