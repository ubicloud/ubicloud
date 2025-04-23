# frozen_string_literal: true

require_relative "../lib/cert_server_setup"
require_relative "../../common/lib/util"
RSpec.describe CertServerSetup do
  subject(:cert_server_setup) { described_class.new(vm_name) }

  let(:vm_name) { "test-vm" }

  describe "#setup" do
    it "copies the server, creates the service, enables and starts the service" do
      expect(cert_server_setup).to receive(:copy_server)
      expect(cert_server_setup).to receive(:create_service)
      expect(cert_server_setup).to receive(:enable_and_start_service)
      expect { cert_server_setup.setup }.not_to raise_error
    end
  end

  describe "#stop_and_remove" do
    it "stops and removes the service, removes the paths" do
      expect(cert_server_setup).to receive(:stop_and_remove_service)
      expect(cert_server_setup).to receive(:remove_paths)
      expect { cert_server_setup.stop_and_remove }.not_to raise_error
    end
  end

  describe "#copy_server" do
    it "downloads the server if it doesn't exist, copies the server, and sets the owner" do
      expect(File).to receive(:exist?).with("/opt/metadata-endpoint-0.1.5").and_return(false)
      expect(cert_server_setup).to receive(:download_server)
      expect(cert_server_setup).to receive(:r).with("cp /opt/metadata-endpoint-0.1.5/metadata-endpoint /vm/test-vm/cert/metadata-endpoint-0.1.5")
      expect(cert_server_setup).to receive(:r).with("sudo chown test-vm:test-vm /vm/test-vm/cert/metadata-endpoint-0.1.5")
      expect { cert_server_setup.copy_server }.not_to raise_error
    end

    it "doesn't download the server if it already exists" do
      expect(File).to receive(:exist?).with("/opt/metadata-endpoint-0.1.5").and_return(true)
      expect(cert_server_setup).not_to receive(:download_server)
      expect(cert_server_setup).to receive(:r).with("cp /opt/metadata-endpoint-0.1.5/metadata-endpoint /vm/test-vm/cert/metadata-endpoint-0.1.5")
      expect(cert_server_setup).to receive(:r).with("sudo chown test-vm:test-vm /vm/test-vm/cert/metadata-endpoint-0.1.5")
      expect { cert_server_setup.copy_server }.not_to raise_error
    end
  end

  describe "#download_server" do
    it "downloads the server, extracts it, and removes the tarball" do
      expect(Arch).to receive(:x64?).and_return(false)
      expect(cert_server_setup).to receive(:r).with("curl -L3 -o /tmp/metadata-endpoint-0.1.5.tar.gz https://github.com/ubicloud/metadata-endpoint/releases/download/v0.1.5/metadata-endpoint_Linux_arm64.tar.gz")
      expect(FileUtils).to receive(:mkdir_p).with("/opt/metadata-endpoint-0.1.5")
      expect(FileUtils).to receive(:cd).with("/opt/metadata-endpoint-0.1.5")
      expect(FileUtils).to receive(:rm_f).with("/tmp/metadata-endpoint-0.1.5.tar.gz")
      expect { cert_server_setup.download_server }.not_to raise_error
    end

    it "downloads the server for x64" do
      expect(Arch).to receive(:x64?).and_return(true)
      expect(cert_server_setup).to receive(:r).with("curl -L3 -o /tmp/metadata-endpoint-0.1.5.tar.gz https://github.com/ubicloud/metadata-endpoint/releases/download/v0.1.5/metadata-endpoint_Linux_x86_64.tar.gz")
      expect(FileUtils).to receive(:mkdir_p).with("/opt/metadata-endpoint-0.1.5")
      expect(FileUtils).to receive(:cd).with("/opt/metadata-endpoint-0.1.5")
      expect(FileUtils).to receive(:rm_f).with("/tmp/metadata-endpoint-0.1.5.tar.gz")
      expect { cert_server_setup.download_server }.not_to raise_error
    end
  end

  describe "#create_service" do
    it "creates the service file" do
      expect(File).to receive(:write).with("/etc/systemd/system/test-vm-metadata-endpoint.service", <<~SERVICE)
[Unit]
Description=Certificate Server
After=network.target

[Service]
NetworkNamespacePath=/var/run/netns/test-vm
ExecStart=/vm/test-vm/cert/metadata-endpoint-0.1.5
Restart=always
RestartSec=15
Type=simple
ProtectSystem=strict
PrivateDevices=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
NoNewPrivileges=yes
ReadOnlyPaths=/vm/test-vm/cert/cert.pem /vm/test-vm/cert/key.pem
User=test-vm
Group=test-vm
Environment=VM_INHOST_NAME=test-vm
Environment=IPV6_ADDRESS="FD00:0B1C:100D:5AFE:CE::"
Environment=GOMEMLIMIT=9MiB
Environment=GOMAXPROCS=1
CPUQuota=50%
MemoryLimit=10M
      SERVICE
      expect(cert_server_setup).to receive(:r).with("systemctl daemon-reload")

      expect { cert_server_setup.create_service }.not_to raise_error
    end
  end

  describe "#enable_and_start_service" do
    it "enables and starts the service" do
      expect(cert_server_setup).to receive(:r).with("systemctl enable --now test-vm-metadata-endpoint")
      cert_server_setup.enable_and_start_service
      # expect { cert_server_setup.enable_and_start_service }.not_to raise_error
    end
  end

  describe "#stop_and_remove_service" do
    it "stops and removes the service" do
      expect(File).to receive(:exist?).with("/etc/systemd/system/test-vm-metadata-endpoint.service").and_return(true)
      expect(cert_server_setup).to receive(:r).with("systemctl disable --now test-vm-metadata-endpoint")
      expect(cert_server_setup).to receive(:r).with("systemctl daemon-reload")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test-vm-metadata-endpoint.service")
      expect { cert_server_setup.stop_and_remove_service }.not_to raise_error
    end

    it "doesn't stop and remove the service if it doesn't exist" do
      expect(File).to receive(:exist?).with("/etc/systemd/system/test-vm-metadata-endpoint.service").and_return(false)
      expect(cert_server_setup).not_to receive(:r).with("systemctl disable --now test-vm-metadata-endpoint")
      expect(cert_server_setup).to receive(:r).with("systemctl daemon-reload")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/test-vm-metadata-endpoint.service")
      expect { cert_server_setup.stop_and_remove_service }.not_to raise_error
    end
  end

  describe "#put_certificate" do
    it "puts the certificate to the server" do
      expect(FileUtils).to receive(:mkdir_p).with("/vm/test-vm/cert")
      expect(cert_server_setup).to receive(:safe_write_to_file).with("/vm/test-vm/cert/cert.pem", "cert")
      expect(cert_server_setup).to receive(:safe_write_to_file).with("/vm/test-vm/cert/key.pem", "key")

      expect { cert_server_setup.put_certificate("cert", "key") }.not_to raise_error
    end
  end

  describe "#remove_paths" do
    it "removes the paths" do
      expect(FileUtils).to receive(:rm_rf).with("/vm/test-vm/cert")
      expect { cert_server_setup.remove_paths }.not_to raise_error
    end
  end
end
