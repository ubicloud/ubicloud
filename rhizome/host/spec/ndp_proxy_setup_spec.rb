# frozen_string_literal: true

require_relative "../lib/ndp_proxy_setup"

RSpec.describe NdpProxySetup do
  subject(:nps) { described_class.new("2a01:4f8:10a:128b::/64") }

  let(:bin) { "/opt/host-ebpf-#{described_class::VERSION}/host-ebpf" }
  let(:tarball) { "/tmp/host-ebpf-#{described_class::VERSION}.tar.gz" }

  describe "#install" do
    it "downloads the binary, writes units, and enables them" do
      calls = []
      expect(nps).to receive(:download_binary) { calls << :download }
      expect(nps).to receive(:write_units) { calls << :units }
      expect(nps).to receive(:r).with("systemctl daemon-reload") { calls << :reload }
      expect(nps).to receive(:r).with("systemctl enable ndp-proxy.service")
      expect(nps).to receive(:r).with("systemctl restart ndp-proxy.service")
      expect(nps).to receive(:r).with("systemctl enable --now ndp-proxy-watch.timer")

      nps.install
      expect(calls).to eq([:download, :units, :reload])
    end
  end

  describe "#download_binary" do
    it "verifies the digest, extracts, and marks the binary executable" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(File.dirname(bin))
      expect(nps).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(nps).to receive(:curl_file).with(nps.package_url, "#{tarball}.tmp")
          .and_return(described_class::PACKAGE_SHA256)
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end
      expect(nps).to receive(:safe_write_to_file).with(bin) do |_, &blk|
        expect(nps).to receive(:r).with("tar -xzOf #{tarball} host-ebpf > #{bin}.tmp")
        expect(FileUtils).to receive(:chmod).with("a+x", "#{bin}.tmp")
        blk.call(instance_double(File, path: "#{bin}.tmp"))
      end
      expect(FileUtils).to receive(:rm_f).with(tarball)

      nps.download_binary
    end

    it "leaves nothing at the trusted path when extraction fails" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(File.dirname(bin))
      expect(nps).to receive(:safe_write_to_file).with(tarball) do |_, &blk|
        expect(nps).to receive(:curl_file).and_return(described_class::PACKAGE_SHA256)
        blk.call(instance_double(File, path: "#{tarball}.tmp"))
      end
      expect(nps).to receive(:safe_write_to_file).with(bin) do |_, &blk|
        expect(nps).to receive(:r).and_raise(CommandFail.new("tar died", "", ""))
        blk.call(instance_double(File, path: "#{bin}.tmp"))
      end

      expect { nps.download_binary }.to raise_error(CommandFail)
    end

    it "fails when the digest does not match" do
      expect(File).to receive(:exist?).with(bin).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(File.dirname(bin))
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
WorkingDirectory=/home/rhizome
ExecStart=/home/rhizome/host/bin/setup-ndp-proxy verify 2a01:4f8:10a:128b::/64
UNIT
      expect(nps).to receive(:safe_write_to_file).with("/etc/systemd/system/ndp-proxy-watch.timer", <<UNIT)
[Unit]
Description=Periodic NDP proxy attachment check

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT

      nps.write_units
    end
  end

  describe "#apply" do
    it "fetches the pinned version and points the binary at the default route device" do
      expect(nps).to receive(:download_binary)
      expect(nps).to receive(:r).with("ip -6 -j route").and_return('[{"dst": "default", "dev": "eth0"}]')
      expect(nps).to receive(:r).with("#{bin} ndp-proxy apply -uplink eth0 -prefix 2a01:4f8:10a:128b::/64")

      nps.apply
    end
  end

  describe "#verify" do
    it "fetches the pinned version and asks the binary to heal any drift" do
      expect(nps).to receive(:download_binary)
      expect(nps).to receive(:r).with("ip -6 -j route").and_return('[{"dst": "default", "dev": "eth0"}]')
      expect(nps).to receive(:r).with("#{bin} ndp-proxy verify -uplink eth0 -prefix 2a01:4f8:10a:128b::/64 -heal")

      nps.verify
    end
  end
end
