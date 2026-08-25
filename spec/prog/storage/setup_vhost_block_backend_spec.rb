# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::SetupVhostBlockBackend do
  subject(:setup_vhost_block_backend) {
    described_class.new(described_class.assemble(vm_host.id, version, allocation_weight: 50))
  }

  let(:version) { "v0.4.2" }

  let(:sshable) { setup_vhost_block_backend.sshable }
  let(:vm_host) { create_vm_host(used_hugepages_1g: 0, total_hugepages_1g: 20, total_cpus: 96, os_version: "ubuntu-24.04") }
  let(:vbb) { VhostBlockBackend.with_pk!(setup_vhost_block_backend.vhost_block_backend_id) }

  describe ".assemble" do
    it "creates a disabled backend and records the options in the frame" do
      st = described_class.assemble(vm_host.id, version, allocation_weight: 50, disable_others: false)
      backend = VhostBlockBackend.with_pk!(st.stack.first["vhost_block_backend_id"])
      expect(backend.version).to eq(version)
      expect(backend.allocation_weight).to eq(0)
      expect(st.stack.first).to eq({"subject_id" => vm_host.id, "version" => version, "allocation_weight" => 50, "disable_others" => false, "vhost_block_backend_id" => backend.id})
    end

    it "fails if version/arch combination is not supported" do
      expect {
        described_class.assemble(vm_host.id, "v1.0")
      }.to raise_error RuntimeError, "Unsupported version: v1.0, x64"
    end
  end

  describe "#start" do
    it "hops to install_vhost_backend" do
      expect { setup_vhost_block_backend.start }.to hop("install_vhost_backend")
    end
  end

  describe "#install_vhost_backend" do
    it "starts the daemonizer if not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vhost-block-backend\\ install\\ #{version} setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap(5)
    end

    it "starts the daemonizer if failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ host/bin/setup-vhost-block-backend\\ install\\ #{version} setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap
    end

    it "updates, disables the other backends and pops if succeeded" do
      older = create_vhost_block_backend(version: "v0.3.1", allocation_weight: 100, vm_host_id: vm_host.id)
      newer = create_vhost_block_backend(version: "v0.5.1", allocation_weight: 100, vm_host_id: vm_host.id)
      other_host_backend = create_vhost_block_backend(version: "v0.4.2", allocation_weight: 100)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to exit({"msg" => "VhostBlockBackend was setup"})
      expect(vbb.reload.allocation_weight).to eq(50)
      expect(older.reload.allocation_weight).to eq(0)
      expect(newer.reload.allocation_weight).to eq(0)
      expect(other_host_backend.reload.allocation_weight).to eq(100)
    end

    it "keeps the other backends enabled if disable_others is false" do
      other = create_vhost_block_backend(version: "v0.3.1", allocation_weight: 100, vm_host_id: vm_host.id)
      refresh_frame(setup_vhost_block_backend, new_values: {"disable_others" => false})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean setup-vhost-block-backend-#{version}")
      expect { setup_vhost_block_backend.install_vhost_backend }.to exit({"msg" => "VhostBlockBackend was setup"})
      expect(vbb.reload.allocation_weight).to eq(50)
      expect(other.reload.allocation_weight).to eq(100)
    end

    it "naps if the daemonizer is already running" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check setup-vhost-block-backend-#{version}").and_return("InProgress")
      expect { setup_vhost_block_backend.install_vhost_backend }.to nap(5)
    end
  end
end
