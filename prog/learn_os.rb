# frozen_string_literal: true

class Prog::LearnOs < Prog::Base
  subject_is :sshable

  label def start
    os_release = sshable.cmd("cat /etc/os-release")
    id = os_release[/^ID="?([^"\n]+)/, 1] or fail "unable to determine OS id from /etc/os-release"
    version_id = os_release[/^VERSION_ID="?([^"\n]+)/, 1] or fail "unable to determine OS version from /etc/os-release"
    pop(os_version: "#{id}-#{version_id}")
  end
end
