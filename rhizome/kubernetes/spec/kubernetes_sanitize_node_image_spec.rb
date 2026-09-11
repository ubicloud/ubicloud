# frozen_string_literal: true

require_relative "../lib/kubernetes_sanitize_node_image"

RSpec.describe KubernetesSanitizeNodeImage do
  subject(:sanitizer) { described_class.new }

  describe "#run" do
    it "runs the sanitize script" do
      expect(sanitizer).to receive(:_run_command).with("bash", "-s", stdin: <<~SH)
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

      sanitizer.run
    end
  end
end
