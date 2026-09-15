# frozen_string_literal: true

require_relative "../lib/ndp_proxy_setup"

RSpec.describe NdpProxySetup do
  subject(:nps) { described_class.new(net6) }

  let(:net6) { "2a01:4f8:10a:128b::/64" }
  let(:install_dir) { "/opt/host-ebpf-#{described_class::VERSION}" }
  let(:bin) { "#{install_dir}/host-ebpf" }
  let(:tarball) { "#{install_dir}/host-ebpf.tar.gz" }
  let(:lock) { instance_double(File) }
  let(:calls) { [] }

  def expect_lock
    expect(File).to receive(:open).with(described_class::LOCK_PATH, File::RDWR | File::CREAT).and_yield(lock)
    expect(lock).to receive(:flock).with(File::LOCK_EX) { calls << :lock }
  end

  describe "#install" do
    it "checks the kernel, downloads under the lock, writes units, and enables them in order" do
      expect(nps).to receive(:_run_command).with("uname -r") do
        calls << :kernel
        "6.8.0-71-generic\n"
      end
      expect_lock
      expect(nps).to receive(:download_binary) { calls << :download }
      expect(nps).to receive(:write_units) { calls << :units }
      expect(nps).to receive(:_run_command).with("systemctl daemon-reload") { calls << :reload }
      expect(nps).to receive(:_run_command).with("systemctl enable ndp-proxy.service") { calls << :enable }
      expect(nps).to receive(:_run_command).with("systemctl restart ndp-proxy.service") { calls << :restart }
      expect(nps).to receive(:_run_command).with("systemctl enable --now ndp-proxy-watch.timer") { calls << :timer }

      nps.install
      expect(calls).to eq([:kernel, :lock, :download, :units, :reload, :enable, :restart, :timer])
    end
  end

  describe "#check_kernel" do
    it "accepts the minimum kernel" do
      expect(nps).to receive(:_run_command).with("uname -r").and_return("6.6.0-14-generic\n")

      expect { nps.check_kernel }.not_to raise_error
    end

    it "refuses an older kernel" do
      expect(nps).to receive(:_run_command).with("uname -r").and_return("5.15.0-1052-generic\n")

      expect { nps.check_kernel }.to raise_error(/Kernel 5.15.0-1052-generic is older than 6.6/)
    end

    it "fails on a release it cannot parse" do
      expect(nps).to receive(:_run_command).with("uname -r").and_return("linux\n")

      expect { nps.check_kernel }.to raise_error(/Cannot parse kernel release "linux"/)
    end
  end

  describe "#download_binary" do
    it "verifies the digest, extracts, and marks the binary executable" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(install_dir)
      expect(nps).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(nps).to receive(:curl_file).with(nps.package_url, "#{tarball}.tmp")
          .and_return(described_class::PACKAGE_SHA256)
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end
      expect(nps).to receive(:safe_write_to_file).with(bin) do |_, &blk|
        expect(nps).to receive(:_run_command).with("tar -xzOf #{tarball} host-ebpf > #{bin}.tmp")
        expect(FileUtils).to receive(:chmod).with("a+x", "#{bin}.tmp")
        blk.call(instance_double(File, path: "#{bin}.tmp"))
      end
      expect(FileUtils).to receive(:rm_f).with(tarball)

      nps.download_binary
    end

    it "leaves nothing at the trusted path when extraction fails" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(install_dir)
      expect(nps).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(nps).to receive(:curl_file).and_return(described_class::PACKAGE_SHA256)
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end
      expect(nps).to receive(:safe_write_to_file).with(bin) do |_, &blk|
        expect(nps).to receive(:_run_command).with("tar -xzOf #{tarball} host-ebpf > #{bin}.tmp")
          .and_raise(CommandFail.new("tar died", "", ""))
        blk.call(instance_double(File, path: "#{bin}.tmp"))
      end

      expect { nps.download_binary }.to raise_error(CommandFail)
    end

    it "fails when the digest does not match" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(install_dir)
      expect(nps).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(nps).to receive(:curl_file).and_return("deadbeef")
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end

      expect { nps.download_binary }.to raise_error(/Invalid SHA-256 digest/)
    end

    it "does not download when the binary is already present" do
      expect(File).to receive(:exist?).with(bin).and_return(true)
      expect(nps).not_to receive(:safe_write_to_file)

      nps.download_binary
    end
  end

  describe "PACKAGE_SHA256" do
    it "is a sha256 digest for the host architecture" do
      expect(described_class::PACKAGE_SHA256).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "#package_url" do
    it "names the release asset for the host architecture" do
      arch = Arch.render(x64: "x86_64", arm64: "arm64")
      expect(nps.package_url).to eq(
        "https://github.com/ubicloud/host-ebpf/releases/download/v#{described_class::VERSION}/" \
        "host-ebpf_Linux_#{arch}.tar.gz",
      )
    end
  end

  describe "#write_units" do
    it "writes the service, watch service, and watch timer" do
      expect(nps).to receive(:safe_write_to_file).with("/etc/systemd/system/ndp-proxy.service", <<UNIT)
[Unit]
Description=Route-following NDP proxy for delegated VM prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=10min
WorkingDirectory=/home/rhizome
ExecStart=/home/rhizome/host/bin/setup-ndp-proxy apply 2a01:4f8:10a:128b::/64

[Install]
WantedBy=multi-user.target
UNIT
      expect(nps).to receive(:safe_write_to_file).with("/etc/systemd/system/ndp-proxy-watch.service", <<UNIT)
[Unit]
Description=Re-attach the NDP proxy if its uplink state drifted

[Service]
Type=oneshot
TimeoutStartSec=10min
WorkingDirectory=/home/rhizome
ExecStart=/home/rhizome/host/bin/setup-ndp-proxy verify 2a01:4f8:10a:128b::/64
UNIT
      expect(nps).to receive(:safe_write_to_file).with("/etc/systemd/system/ndp-proxy-watch.timer", <<UNIT)
[Unit]
Description=Periodic NDP proxy attachment check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

      nps.write_units
    end
  end

  describe "#apply" do
    it "fetches the pinned version and points the binary at the default route device, under the lock" do
      expect_lock
      expect(nps).to receive(:download_binary) { calls << :download }
      expect(nps).to receive(:_run_command).with("ip -6 -j route").and_return('[{"dst": "default", "dev": "eth0"}]')
      expect(nps).to receive(:_run_command).with("ip -j route").and_return('[{"dst": "default", "dev": "eth1"}]')
      expect(nps).to receive(:_run_command).with(bin, "ndp-proxy", "apply", "-uplink", "eth0", "-prefix", net6) { calls << :apply }

      nps.apply
      expect(calls).to eq([:lock, :download, :apply])
    end

    it "falls back to the IPv4 table when the host has no IPv6 default route" do
      expect_lock
      expect(nps).to receive(:download_binary)
      expect(nps).to receive(:_run_command).with("ip -6 -j route").and_return('[{"dst": "2a04:2181:c011:3::/64", "dev": "eth0"}]')
      expect(nps).to receive(:_run_command).with("ip -j route").and_return('[{"dst": "default", "dev": "eth0"}]')
      expect(nps).to receive(:_run_command).with(bin, "ndp-proxy", "apply", "-uplink", "eth0", "-prefix", net6)

      nps.apply
    end
  end

  describe "#verify" do
    it "fetches the pinned version and asks the binary to heal any drift, under the lock" do
      expect_lock
      expect(nps).to receive(:download_binary) { calls << :download }
      expect(nps).to receive(:_run_command).with("ip -6 -j route").and_return('[{"dst": "default", "dev": "eth0"}]')
      expect(nps).to receive(:_run_command).with("ip -j route").and_return("[]")
      expect(nps).to receive(:_run_command).with(bin, "ndp-proxy", "verify", "-uplink", "eth0", "-prefix", net6, "-heal") { calls << :verify }

      nps.verify
      expect(calls).to eq([:lock, :download, :verify])
    end
  end
end
