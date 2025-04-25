# frozen_string_literal: true

require_relative "../lib/spdk_setup"

RSpec.describe SpdkSetup do
  subject(:spdk_setup) { described_class.new(spdk_version) }

  let(:spdk_version) { DEFAULT_SPDK_VERSION }

  describe "#prep" do
    it "can prep host for spdk" do
      expect(described_class).to receive(:r).with(/apt-get -y .*/)
      expect(described_class).to receive(:r).with(/adduser .*/)
      expect(FileUtils).to receive(:mkdir_p).with(SpdkPath.vhost_dir)
      expect(FileUtils).to receive(:chown).with("spdk", "spdk", SpdkPath.vhost_dir)
      expect { described_class.prep }.not_to raise_error
    end

    it "continues if user already exists" do
      expect(described_class).to receive(:r).with(/apt-get -y .*/)
      expect(described_class).to receive(:r).with(/adduser .*/).and_raise CommandFail.new("adduser: The user `spdk' already exists.", "", "")
      expect(FileUtils).to receive(:mkdir_p).with(SpdkPath.vhost_dir)
      expect(FileUtils).to receive(:chown).with("spdk", "spdk", SpdkPath.vhost_dir)
      expect { described_class.prep }.not_to raise_error
    end

    it "fails if adduser fails with an unexpected error" do
      expect(described_class).to receive(:r).with(/apt-get -y .*/)
      expect(described_class).to receive(:r).with(/adduser .*/).and_raise CommandFail.new("adduser: some other error.", "", "")
      expect { described_class.prep }.to raise_error CommandFail
    end
  end

  describe "#package_url" do
    it "returns a valid url for x64" do
      allow(Arch).to receive(:sym).and_return(:x64)
      expect(spdk_setup.package_url(os_version: "ubuntu-22.04")).to match(/https.*x64.*tar.gz/)
    end

    it "returns a valid url for arm64" do
      allow(Arch).to receive(:sym).and_return(:arm64)
      expect(spdk_setup.package_url(os_version: "ubuntu-22.04")).to match(/https.*arm64.*tar.gz/)
    end
  end

  describe "#install_package" do
    it "can install the package" do
      expect(spdk_setup).to receive(:package_url).and_return("package_url")
      allow(spdk_setup).to receive(:install_path).and_return("install_path")
      expect(spdk_setup).to receive(:r).with(/curl -L3 -o .* package_url/)
      expect(FileUtils).to receive(:mkdir_p).with("install_path")
      expect(FileUtils).to receive(:cd).with("install_path")
      expect { spdk_setup.install_package(os_version: "ubuntu-22.04") }.not_to raise_error
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
      expect { spdk_setup.create_hugepages_mount }.not_to raise_error
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
