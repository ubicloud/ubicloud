# frozen_string_literal: true

require_relative "../lib/kubernetes_build_node_image"

RSpec.describe KubernetesBuildNodeImage do
  subject(:builder) { described_class.new(["v1.35"]) }

  describe "#initialize" do
    it "rejects a missing version" do
      expect { described_class.new([]) }.to raise_error RuntimeError, "expected a single argument, a kubernetes version like v1.35, got 0"
    end

    it "rejects extra arguments" do
      expect { described_class.new(["v1.35", "x64"]) }.to raise_error RuntimeError, "expected a single argument, a kubernetes version like v1.35, got 2"
    end

    it "rejects a version that is not a kubernetes minor version" do
      expect { described_class.new(["1.35"]) }.to raise_error RuntimeError, "expected a kubernetes version like v1.35, got \"1.35\""
    end
  end

  describe "#run" do
    it "installs kubernetes and containerd for the requested version" do
      commands = []
      stdins = {}
      allow(builder).to receive(:_run_command) do |command, **kw|
        commands << command
        stdins[command] = kw[:stdin] if kw[:stdin]
        (command == "containerd config default") ? "  SystemdCgroup = false\n" : ""
      end

      builder.run

      expect(commands).to eq [
        "tee /etc/sysctl.d/72-clover-forward-packets.conf > /dev/null",
        "apt-get update",
        "apt-get full-upgrade -y",
        "apt-get install -y ca-certificates curl gpg",
        "install -m 0755 -d /etc/apt/keyrings",
        "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key -o /tmp/kubernetes-release.key",
        "gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/kubernetes-release.key",
        "rm -f /tmp/kubernetes-release.key",
        "echo deb\\ \\[signed-by\\=/etc/apt/keyrings/kubernetes-apt-keyring.gpg\\]\\ https://pkgs.k8s.io/core:/stable:/v1.35/deb/\\ / | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null",
        "apt-get update",
        "apt-get install -y containerd cri-tools kubelet kubeadm kubectl ruby-bundler",
        "apt-get install -y linux-modules-extra-$(linux-version list | linux-version sort | tail -1)",
        "mkdir -p /etc/containerd",
        "containerd config default",
        "tee /etc/containerd/config.toml > /dev/null",
        "kubernetes/bin/install-node-exporter",
        "kubernetes/bin/install-prometheus",
        "apt-mark hold kubelet kubeadm kubectl",
        "systemctl disable unattended-upgrades",
      ]
      expect(stdins).to eq(
        "tee /etc/sysctl.d/72-clover-forward-packets.conf > /dev/null" => described_class::SYSCTL_CONF,
        "tee /etc/containerd/config.toml > /dev/null" => "  SystemdCgroup = true\n",
      )
      expect(ENV["DEBIAN_FRONTEND"]).to eq "noninteractive"
    end
  end
end
