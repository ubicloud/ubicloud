# frozen_string_literal: true

require_relative "../lib/spdk_setup"

RSpec.describe SpdkSetup do
  subject(:spdk_setup) { described_class.new(spdk_version) }

  let(:spdk_version) { DEFAULT_SPDK_VERSION }

  describe "#prep" do
    before do
      expect(described_class).to receive(:r).with("apt-get -y install libaio-dev libssl-dev libnuma-dev libjson-c-dev uuid-dev libiscsi-dev")
    end

    it "can prep host for spdk" do
      expect(described_class).to receive(:r).with("adduser spdk --disabled-password --gecos '' --home /home/spdk")
      expect(FileUtils).to receive(:mkdir_p).with(SpdkPath.vhost_dir)
      expect(FileUtils).to receive(:chown).with("spdk", "spdk", SpdkPath.vhost_dir)
      described_class.prep
    end

    it "continues if user already exists (ubuntu 22.04)" do
      expect(described_class).to receive(:r).with("adduser spdk --disabled-password --gecos '' --home /home/spdk")
        .and_raise CommandFail.new("Warning: The home dir /home/spdk you specified already exists.\nadduser: The user `spdk' already exists.", "", "")
      expect(FileUtils).to receive(:mkdir_p).with(SpdkPath.vhost_dir)
      expect(FileUtils).to receive(:chown).with("spdk", "spdk", SpdkPath.vhost_dir)
      described_class.prep
    end

    it "continues if user already exists (ubuntu 24.04)" do
      expect(described_class).to receive(:r).with("adduser spdk --disabled-password --gecos '' --home /home/spdk")
        .and_raise CommandFail.new("info: The home dir /home/spdk you specified already exists.\n\nfatal: The user `spdk' already exists.", "", "")
      expect(FileUtils).to receive(:mkdir_p).with(SpdkPath.vhost_dir)
      expect(FileUtils).to receive(:chown).with("spdk", "spdk", SpdkPath.vhost_dir)
      described_class.prep
    end

    it "fails if adduser fails with an unexpected error" do
      expect(described_class).to receive(:r).with("adduser spdk --disabled-password --gecos '' --home /home/spdk")
        .and_raise CommandFail.new("adduser: some other error.", "", "")
      expect { described_class.prep }.to raise_error CommandFail
    end
  end

  describe "#package_url" do
    it "returns a valid url for x64" do
      expect(Arch).to receive(:sym).and_return(:x64)
      expect(spdk_setup.package_url(os_version: "ubuntu-22.04")).to match(/https.*x64.*tar.gz/)
    end

    it "returns a valid url for arm64" do
      expect(Arch).to receive(:sym).and_return(:arm64)
      expect(spdk_setup.package_url(os_version: "ubuntu-22.04")).to match(/https.*arm64.*tar.gz/)
    end

    it "raises for an unsupported SPDK version" do
      setup = described_class.new("unknown-version")
      expect { setup.package_url(os_version: "ubuntu-22.04") }.to raise_error("BUG: unsupported SPDK version")
    end
  end

  describe "#install_package" do
    it "can install the package" do
      expect(spdk_setup).to receive(:package_url).and_return("package_url")
      expect(spdk_setup).to receive(:puts).with("Downloading SPDK package from package_url")
      expect(spdk_setup).to receive(:install_path).and_return("install_path").at_least(:once)
      expect(spdk_setup).to receive(:r).with("curl -L3 -o /tmp/spdk.tar.gz package_url")
      expect(FileUtils).to receive(:mkdir_p).with("install_path")
      expect(FileUtils).to receive(:cd).with("install_path").and_yield
      expect(spdk_setup).to receive(:r).with("tar -xzf /tmp/spdk.tar.gz --strip-components=1")
      spdk_setup.install_package(os_version: "ubuntu-22.04")
    end
  end

  describe "#create_service" do
    it "creates the service file" do
      expect(File).to receive(:write).with("/lib/systemd/system/spdk-#{spdk_version}.service", /.*/)
      expect { spdk_setup.create_service(cpu_count: 4) }.not_to raise_error
    end
  end

  describe "#create_hugepages_mount" do
    it "creates the hugepages mount" do
      expect(spdk_setup).to receive(:r).with("sudo --user=spdk mkdir -p /home/spdk/hugepages.#{spdk_version.tr("-", ".")}")
      expect(File).to receive(:write).with("/lib/systemd/system/home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount", /.*/)
      spdk_setup.create_hugepages_mount(cpu_count: 4)
    end
  end

  describe "#create_conf" do
    it "writes json config with correct subsystems" do
      expect(spdk_setup).to receive(:safe_write_to_file).with(
        SpdkPath.conf_path(spdk_version),
        satisfy { |content|
          parsed = JSON.parse(content)
          subsystems = parsed["subsystems"].map { _1["subsystem"] }
          subsystems == ["iobuf", "accel", "bdev"]
        },
      )
      spdk_setup.create_conf(cpu_count: 4)
    end
  end

  describe "#stop_and_remove_services" do
    it "stops and removes services and unit files" do
      expect(spdk_setup).to receive(:r).with("systemctl stop spdk-#{spdk_version}.service")
      expect(spdk_setup).to receive(:r).with("systemctl stop home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount")
      expect(spdk_setup).to receive(:r).with("systemctl disable spdk-#{spdk_version}.service")
      expect(spdk_setup).to receive(:r).with("systemctl disable home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount")
      expect(FileUtils).to receive(:rm_f).with("/lib/systemd/system/spdk-#{spdk_version}.service")
      expect(FileUtils).to receive(:rm_f).with("/lib/systemd/system/home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount")
      spdk_setup.stop_and_remove_services
    end
  end

  describe "#remove_paths" do
    it "removes conf, hugepages dir, and install path" do
      expect(FileUtils).to receive(:rm_f).with(SpdkPath.conf_path(spdk_version))
      expect(FileUtils).to receive(:rm_rf).with(spdk_setup.hugepages_dir)
      expect(FileUtils).to receive(:rm_rf).with(spdk_setup.install_path)
      spdk_setup.remove_paths
    end
  end

  describe "#enable_services" do
    it "enables services" do
      expect(spdk_setup).to receive(:r).with("systemctl enable spdk-#{spdk_version}.service")
      expect(spdk_setup).to receive(:r).with("systemctl enable home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount")
      expect { spdk_setup.enable_services }.not_to raise_error
    end
  end

  describe "#start_services" do
    it "starts services" do
      expect(spdk_setup).to receive(:r).with("systemctl start spdk-#{spdk_version}.service")
      expect(spdk_setup).to receive(:r).with("systemctl start home-spdk-hugepages.#{spdk_version.tr("-", ".")}.mount")
      expect { spdk_setup.start_services }.not_to raise_error
    end
  end

  describe "#vhost_target" do
    it "returns 'vhost_ubi' for a ubi spdk version" do
      expect(spdk_setup.vhost_target).to eq("vhost_ubi")
    end

    it "returns 'vhost' for a non-ubi spdk version" do
      non_ubi_setup = described_class.new("v24.01.0")
      expect(non_ubi_setup.vhost_target).to eq("vhost")
    end
  end

  describe "#verify_spdk" do
    it "succeeds if is active" do
      expect(spdk_setup).to receive(:r).with("systemctl is-active spdk-#{spdk_version}.service").and_return("active\n")
      expect { spdk_setup.verify_spdk }.not_to raise_error
    end

    it "fails if not active" do
      expect(spdk_setup).to receive(:r).with("systemctl is-active spdk-#{spdk_version}.service").and_return("inactive\n")
      expect { spdk_setup.verify_spdk }.to raise_error RuntimeError, "SPDK failed to start"
    end
  end
end
