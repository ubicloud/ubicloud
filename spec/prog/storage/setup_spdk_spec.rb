# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::SetupSpdk do
  subject(:ss) {
    described_class.new(described_class.assemble(
      "adec2977-74a9-8b71-8473-cf3940a45ac5",
      spdk_version,
      start_service: true,
      allocation_weight: 50
    ))
  }

  let(:spdk_version) { "v23.09" }
  let(:sshable) {
    instance_double(Sshable)
  }
  let(:vm_host) {
    Sshable.create { _1.id = "adec2977-74a9-8b71-8473-cf3940a45ac5" }
    VmHost.create(location: "xyz", arch: "x64") { _1.id = "adec2977-74a9-8b71-8473-cf3940a45ac5" }
  }

  before do
    allow(ss).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "hops to install_spdk" do
      expect(vm_host).to receive(:spdk_installations).and_return([])
      expect { ss.start }.to hop("install_spdk")
    end

    it "fails if version/arch combination is not supported" do
      expect(ss).to receive(:frame).and_return({"version" => "v1.0"})
      expect { ss.start }.to raise_error RuntimeError, "Unsupported version: v1.0, x64"
    end

    it "fails if already contains 2 installations" do
      expect(vm_host).to receive(:spdk_installations).and_return(["spdk_1", "spdk_2"])
      expect { ss.start }.to raise_error RuntimeError, "Can't install more than 2 SPDKs on a host"
    end
  end

  describe "#install_spdk" do
    it "installs and hops to start_service" do
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk install #{spdk_version}")
      expect { ss.install_spdk }.to hop("start_service")
    end
  end

  describe "#start_service" do
    it "installs service and hops to update_database" do
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk start #{spdk_version}")
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk verify #{spdk_version}")
      expect { ss.start_service }.to hop("update_database")
    end

    it "skips installing service if not asked to" do
      ss2 = described_class.new(described_class.assemble(vm_host.id, spdk_version, start_service: false))
      expect { ss2.start_service }.to hop("update_database")
    end
  end

  describe "#update_database" do
    it "updates the database and exits" do
      vm_host = instance_double(VmHost)
      expect(ss).to receive(:vm_host).and_return(vm_host)
      expect(vm_host).to receive(:id).and_return(VmHost.generate_uuid)
      expect { ss.update_database }.to exit({"msg" => "SPDK was setup"})
    end
  end
end
