# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RestartSpdk do
  subject(:rs) {
    described_class.new(vm_host.restart_spdk)
  }

  let(:vm_host) {
    ubid = VmHost.generate_ubid
    Sshable.create(host: "hostname") { _1.id = ubid.to_uuid }
    vm_host = VmHost.create(location: "xyz") { _1.id = ubid.to_uuid }

    vm = Vm.create_with_id(vm_host_id: vm_host.id, unix_user: "x", public_key: "x", name: "x", family: "x", cores: 2, location: "x", boot_image: "x")
    VmStorageVolume.create_with_id(vm_id: vm.id, size_gib: 5, disk_index: 0, boot: false)

    vm_host
  }

  describe "#start" do
    it "transitions to wait_until_vms_idle if vm_host is accepting" do
      allow(rs).to receive(:vm_host).and_return(vm_host)
      expect(vm_host).to receive(:allocation_state).and_return("accepting")
      expect(vm_host).to receive(:update).with(allocation_state: "updating")
      expect { rs.start }.to hop("wait_until_vms_idle")
    end

    it "fails if vm_host is not accepting" do
      expect { rs.start }.to raise_error RuntimeError, "Host not in accepting mode"
    end
  end

  describe "#wait_until_vms_idle" do
    it "hops to restart if vms are idle" do
      expect(rs).to receive(:vms_not_waiting).and_return(0)
      expect { rs.wait_until_vms_idle }.to hop("restart")
    end

    it "naps if some vms are not waiting" do
      expect(rs).to receive(:vms_not_waiting).and_return(1)
      expect { rs.wait_until_vms_idle }.to nap(30)
    end
  end

  describe "#restart" do
    it "enables spdk and exits" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo systemctl stop spdk")
      expect(sshable).to receive(:cmd).with("sudo systemctl start spdk")
      expect(sshable).to receive(:cmd).with("sudo host/bin/storage-ctl start-volumes", stdin: /{.*}/)
      expect(rs).to receive(:sshable).and_return(sshable).at_least(:once)
      expect { rs.restart }.to exit({"msg" => "SPDK was restarted"})
    end
  end

  describe "#vms_not_waiting" do
    it "returns number of not waiting VMs" do
      expect(rs.vms_not_waiting).to eq(0)
    end
  end
end
