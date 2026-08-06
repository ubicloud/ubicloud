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
        "sudo tee /etc/sysctl.d/72-clover-forward-packets.conf > /dev/null",
        "sudo -E apt-get update",
        "sudo -E apt-get upgrade -y",
        "sudo -E apt-get install -y ca-certificates curl gpg",
        "sudo install -m 0755 -d /etc/apt/keyrings",
        "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key -o /tmp/kubernetes-release.key",
        "sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/kubernetes-release.key",
        "rm -f /tmp/kubernetes-release.key",
        "echo deb\\ \\[signed-by\\=/etc/apt/keyrings/kubernetes-apt-keyring.gpg\\]\\ https://pkgs.k8s.io/core:/stable:/v1.35/deb/\\ / | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null",
        "sudo -E apt-get update",
        "sudo -E apt-get install -y containerd cri-tools kubelet kubeadm kubectl ruby-bundler",
        "sudo mkdir -p /etc/containerd",
        "containerd config default",
        "sudo tee /etc/containerd/config.toml > /dev/null",
        "kubernetes/bin/install-node-exporter",
        "kubernetes/bin/install-prometheus",
        "sudo apt-mark hold kubelet kubeadm kubectl",
        "sudo systemctl disable unattended-upgrades",
        "sudo -E apt-get autoremove -y",
        "sudo -E apt-get clean",
        "sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*",
      ]
      expect(stdins).to eq(
        "sudo tee /etc/sysctl.d/72-clover-forward-packets.conf > /dev/null" => described_class::SYSCTL_CONF,
        "sudo tee /etc/containerd/config.toml > /dev/null" => "  SystemdCgroup = true\n",
      )
      expect(ENV["DEBIAN_FRONTEND"]).to eq "noninteractive"
    end
  end
end
