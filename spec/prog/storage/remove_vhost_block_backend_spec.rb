# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RemoveVhostBlockBackend do
  subject(:remove_vhost_block_backend) do
    described_class.new(described_class.assemble(
      "4b18e095-5f64-8c66-8d62-1f1d8c75c2fa"
    ))
  end

  let(:sshable) { instance_double(Sshable) }
  let(:vm_host) { instance_double(VmHost) }
  let(:vhost_block_backend) { instance_double(VhostBlockBackend) }

  before do
    allow(remove_vhost_block_backend).to receive(:vhost_block_backend).and_return(vhost_block_backend)
    allow(vm_host).to receive_messages(
      vhost_block_backends: [vhost_block_backend, instance_double(VhostBlockBackend)],
      sshable: sshable,
      spdk_installations: []
    )
    allow(vhost_block_backend).to receive_messages(
      vm_host: vm_host,
      version: "v0.2.0",
      vm_storage_volumes: []
    )
  end

  describe "#start" do
    it "hops to wait_volumes" do
      expect(vhost_block_backend).to receive(:update).with(allocation_weight: 0)
      expect(remove_vhost_block_backend).to receive(:register_deadline).with(nil, 4 * 60 * 60)
      expect { remove_vhost_block_backend.start }.to hop("wait_volumes")
    end

    it "fails if this is the last storage backend" do
      expect(vm_host).to receive(:vhost_block_backends).and_return([vhost_block_backend])
      expect(vm_host).to receive(:spdk_installations).and_return([])
      expect { remove_vhost_block_backend.start }.to raise_error RuntimeError, "Can't remove the last storage backend from the host"
    end

    it "does not fail if there are other storage backends" do
      expect(vm_host).to receive(:vhost_block_backends).and_return([vhost_block_backend])
      expect(vm_host).to receive(:spdk_installations).and_return([instance_double(SpdkInstallation)])
      expect(vhost_block_backend).to receive(:update).with(allocation_weight: 0)
      expect { remove_vhost_block_backend.start }.to hop("wait_volumes")
    end
  end

  describe "#wait_volumes" do
    it "waits until all volumes using the backend are destroyed" do
      expect(vhost_block_backend).to receive(:vm_storage_volumes).and_return([:vm])
      expect(remove_vhost_block_backend).not_to receive(:register_deadline)
      expect { remove_vhost_block_backend.wait_volumes }.to nap(30)
    end

    it "hops to remove_vhost_block_backend if no volumes are using the backend" do
      expect(vhost_block_backend).to receive(:vm_storage_volumes).and_return([])
      expect(remove_vhost_block_backend).to receive(:register_deadline).with(nil, 5 * 60)
      expect { remove_vhost_block_backend.wait_volumes }.to hop("remove_vhost_block_backend")
    end
  end

  describe "#remove_vhost_block_backend" do
    it "pops after removing the backend" do
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-vhost-block-backend remove v0.2.0")
      expect(vhost_block_backend).to receive(:destroy)
      expect { remove_vhost_block_backend.remove_vhost_block_backend }.to exit({"msg" => "VhostBlockBackend was removed"})
    end
  end
end
