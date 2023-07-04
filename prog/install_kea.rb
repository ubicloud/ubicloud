# frozen_string_literal: true

class Prog::InstallKea < Prog::Base
  subject_is :sshable

  def start
    sshable.cmd("sudo apt-get -y install kea")
    sshable.cmd("sudo setcap cap_net_raw+ep /usr/sbin/kea-dhcp4")
    sshable.cmd("sudo setcap cap_net_raw+ep /usr/sbin/kea-dhcp6")

    sshable.cmd("sudo apt-get -y install radvd")

    pop "installed kea"
  end
end
