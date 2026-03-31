# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::SetupVhostBlockBackend do
  subject(:setup_vhost_block_backend) {
    described_class.new(described_class.assemble(
      vm_host.id,
      Config.vhost_block_backend_version,
      allocation_weight: 50
    ))
  }

  let(:version) { Config.vhost_block_backend_version }

  let(:sshable) { setup_vhost_block_backend.sshable }
  let(:vm_host) { create_vm_host(used_hugepages_1g: 0, total_hugepages_1g: 20, total_cpus: 96, os_version: "ubuntu-24.04") }

  describe "#start" do
    it "hops to install_vhost_backend" do
      expect { setup_vhost_block_backend.start }.to hop("install_vhost_backend")
    end

    it "fails if version/arch combination is not supported" do
      refresh_frame(setup_vhost_block_backend, new_values: {"version" => "v1.0"})
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
      create_vhost_block_backend(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vhost-block-backend\\ install\\ #{version} setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap
    end

    it "updates and pops if succeeded" do
      vbb = create_vhost_block_backend(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      refresh_frame(setup_vhost_block_backend, new_values: {"vhost_block_backend_id" => vbb.id})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to exit({"msg" => "VhostBlockBackend was setup"})
      expect(VhostBlockBackend.first.allocation_weight).to eq(50)
    end

    it "naps if the daemonizer is already running" do
      create_vhost_block_backend(version: version.to_s, allocation_weight: 0, vm_host_id: vm_host.id)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("InProgress")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap(5)
    end
  end
end
