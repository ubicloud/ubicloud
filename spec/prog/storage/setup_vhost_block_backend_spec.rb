# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::SetupVhostBlockBackend do
  subject(:setup_vhost_block_backend) {
    described_class.new(described_class.assemble(
      "adec2977-74a9-8b71-8473-cf3940a45ac5",
      Config.vhost_block_backend_version,
      allocation_weight: 50
    ))
  }

  let(:version) { Config.vhost_block_backend_version }

  let(:sshable) { vm_host.sshable }
  let(:vm_host) { create_vm_host(used_hugepages_1g: 0, total_hugepages_1g: 20, total_cpus: 96, os_version: "ubuntu-24.04") }

  before do
    allow(setup_vhost_block_backend).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "hops to install_vhost_backend" do
      expect { setup_vhost_block_backend.start }.to hop("install_vhost_backend")
    end

    it "fails if version/arch combination is not supported" do
      expect(setup_vhost_block_backend).to receive(:frame).and_return({"version" => "v1.0"})
      expect { setup_vhost_block_backend.start }.to raise_error RuntimeError, "Unsupported version: v1.0, x64"
    end
  end

  describe "#install_vhost_backend" do
    it "starts the daemonizer if not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vhost-block-backend\\ install\\ #{version} setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap(5)
    end

    it "starts the daemonizer if failed" do
      VhostBlockBackend.create(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vhost-block-backend\\ install\\ #{version} setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap
    end

    it "updates and pops if succeeded" do
      VhostBlockBackend.create(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to exit({"msg" => "VhostBlockBackend was setup"})
      expect(VhostBlockBackend.first.allocation_weight).to eq(50)
    end

    it "naps if the daemonizer is already running" do
      VhostBlockBackend.create(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("InProgress")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap(5)
    end
  end
end
