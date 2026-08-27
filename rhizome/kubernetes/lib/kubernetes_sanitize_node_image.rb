# frozen_string_literal: true

require_relative "../../common/lib/util"

class KubernetesSanitizeNodeImage
  SCRIPT = <<~SH
    set -ueo pipefail
    export DEBIAN_FRONTEND=noninteractive

    sudo -E apt-get autoremove -y
    sudo -E apt-get clean
    sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

    sudo rm -rf /var/lib/cloud
    sudo cloud-init clean --logs
    sudo journalctl --rotate
    sudo journalctl --vacuum-time=1s
    sudo rm -f /etc/ssh/ssh_host_*
    sudo truncate -s 0 /etc/machine-id
    sudo truncate -s 0 /home/ubi/.ssh/authorized_keys
  SH

  def run
    r("bash", "-s", stdin: SCRIPT)
  end
end
