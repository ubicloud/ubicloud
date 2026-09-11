# frozen_string_literal: true

require_relative "../../common/lib/util"

class KubernetesSanitizeNodeImage
  SCRIPT = <<~SH
    set -ueo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get autoremove -y
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

    rm -rf /var/lib/cloud
    cloud-init clean --logs
    journalctl --rotate
    journalctl --vacuum-time=1s
    rm -f /etc/ssh/ssh_host_*
    truncate -s 0 /etc/machine-id
    truncate -s 0 /home/ubi/.ssh/authorized_keys
  SH

  def run
    r("bash", "-s", stdin: SCRIPT)
  end
end
