# frozen_string_literal: true

require_relative "../lib/runner_metrics_setup"

RSpec.describe RunnerMetricsSetup do
  subject(:setup) { described_class.new("vmabc") }

  let(:bin) { "/opt/runner-metrics/0.1.0/runner-metrics" }
  let(:tarball) { "/opt/runner-metrics/0.1.0/runner-metrics.tar.gz" }

  describe "#package_url" do
    it "points at the release for the host architecture" do
      expect(Arch).to receive(:render).with(x64: "amd64", arm64: "arm64").and_return("arm64")
      expect(setup.package_url).to eq("https://github.com/ubicloud/runner-metrics/releases/download/0.1.0/runner-metrics-linux-arm64-0.1.0.tar.gz")
    end
  end

  describe "#download_binary" do
    it "verifies the digest, extracts, and marks the binary executable" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/runner-metrics/0.1.0")
      expect(setup).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(setup).to receive(:curl_file).with(setup.package_url, "#{tarball}.tmp").and_return(described_class::SHA256_BY_ARCH.fetch(Arch.sym))
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end
      expect(setup).to receive(:safe_write_to_file).with(bin) do |_, &blk|
        expect(setup).to receive(:_run_command).with("tar -xzOf #{tarball} runner-metrics > #{bin}.tmp")
        expect(FileUtils).to receive(:chmod).with(0o755, "#{bin}.tmp")
        blk.call(instance_double(File, path: "#{bin}.tmp"))
      end
      expect(FileUtils).to receive(:rm_f).with(tarball)

      setup.download_binary
    end

    it "fails on a digest mismatch" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/runner-metrics/0.1.0")
      expect(setup).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(setup).to receive(:curl_file).with(setup.package_url, "#{tarball}.tmp").and_return("bad")
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end

      expect { setup.download_binary }.to raise_error(RuntimeError, "Invalid SHA-256 digest")
    end

    it "does nothing when the binary is already installed" do
      expect(File).to receive(:exist?).with(bin).and_return(true)
      expect(FileUtils).not_to receive(:mkdir_p)

      setup.download_binary
    end
  end

  describe "#setup" do
    it "writes the labels and starts the listener in the vm's network namespace" do
      expect(File).to receive(:exist?).with(bin).and_return(true)
      expect(FileUtils).to receive(:mkdir_p).with(["/vm/vmabc/metrics/pending", "/vm/vmabc/metrics/done"])
      expect(setup).to receive(:safe_write_to_file).with("/vm/vmabc/metrics/labels.json", '{"vm":"vm123"}')
      expect(setup).to receive(:_run_command).with("chown", "-R", "vmabc:vmabc", "/vm/vmabc/metrics")
      expect(setup).to receive(:safe_write_to_file).with("/etc/systemd/system/vmabc-metrics.service", <<~SERVICE)
        [Unit]
        Description=Runner metrics listener for vmabc
        After=network.target

        [Service]
        NetworkNamespacePath=/var/run/netns/vmabc
        ExecStart=/opt/runner-metrics/0.1.0/runner-metrics /vm/vmabc/metrics
        Restart=always
        RestartSec=2
        User=vmabc
        Group=vmabc
        ProtectSystem=strict
        ReadWritePaths=/vm/vmabc/metrics
        PrivateTmp=yes
        NoNewPrivileges=yes
        MemoryMax=32M
        CPUQuota=20%

        [Install]
        WantedBy=multi-user.target
      SERVICE
      expect(setup).to receive(:_run_command).with("systemctl", "daemon-reload")
      expect(setup).to receive(:_run_command).with("systemctl", "enable", "--now", "vmabc-metrics")

      setup.setup({"vm" => "vm123"})
    end
  end

  describe "#stop_and_remove" do
    it "stops the service and removes its files" do
      expect(File).to receive(:exist?).with("/etc/systemd/system/vmabc-metrics.service").and_return(true)
      expect(setup).to receive(:_run_command).with("systemctl", "disable", "--now", "vmabc-metrics")
      expect(FileUtils).to receive(:rm_r).with("/etc/systemd/system/vmabc-metrics.service")
      expect(setup).to receive(:_run_command).with("systemctl", "daemon-reload")
      expect(FileUtils).to receive(:rm_r).with("/etc/systemd/system/vmabc-metrics.service.tmp.lock")
      expect(FileUtils).to receive(:rm_r).with("/vm/vmabc/metrics")

      setup.stop_and_remove
    end

    it "only removes leftover files when the service is not installed" do
      expect(File).to receive(:exist?).with("/etc/systemd/system/vmabc-metrics.service").and_return(false)
      expect(FileUtils).to receive(:rm_r).with("/etc/systemd/system/vmabc-metrics.service.tmp.lock").and_raise(Errno::ENOENT)
      expect(FileUtils).to receive(:rm_r).with("/vm/vmabc/metrics")

      setup.stop_and_remove
    end
  end
end
