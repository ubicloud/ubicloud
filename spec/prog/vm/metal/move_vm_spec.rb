# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe Prog::Vm::Metal::MoveVm do
  describe ".assemble" do
    let(:project) { Project.create(name: "move-vm-project") }

    let(:private_subnet) {
      PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: project.id)
    }

    let(:source_host) {
      vm_host = create_vm_host(location_id: Location::HETZNER_FSN1_ID)
      VhostBlockBackend.create(version: "0.5.1", allocation_weight: 100, vm_host_id: vm_host.id)
      vm_host
    }

    let(:vm) {
      v = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, vm_host_id: source_host.id, name: "old-vm")
      Nic.create(private_subnet_id: private_subnet.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "old-vm-nic",
        vm_id: v.id,
        state: "active")
      vbb = create_vhost_block_backend(vm_host_id: source_host.id)
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: source_host.id)
      VmStorageVolume.create(vm_id: v.id, boot: true, size_gib: 40, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "src").id,
        vring_workers: 1, track_written: true)
      Strand.create_with_id(v.id, prog: "Vm::Metal::Nexus", label: "stopped_by_admin")
      v.incr_prepare_to_move
      v
    }

    let(:vm_host) {
      h = create_vm_host(location_id: Location::HETZNER_FSN1_ID, total_cpus: 48, total_cores: 48,
        used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16)
      StorageDevice.create(name: "target-vda", total_storage_gib: 100, available_storage_gib: 100, vm_host_id: h.id)
      h
    }

    it "fails if the vm's strand is not at the stopped_by_admin label" do
      vm.strand.update(label: "wait")
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "Vm is not ready to move")
    end

    it "fails if the prepare_to_move semaphore is not set" do
      vm.decr_prepare_to_move
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "Vm is not ready to move")
    end

    it "fails if the vm_host is in a different location than the vm" do
      vm_host.update(location_id: Location::HETZNER_HEL1_ID)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost is not in the same location as the Vm")
    end

    it "fails if the vm_host has different arch than the vm" do
      vm_host.update(arch: "arm64")
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost arch does not match Vm arch")
    end

    it "fails if the vm is burstable and host does not accept slices" do
      vm.update(family: "burstable")
      vm_host.update(accepts_slices: false)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost does not accept slices and Vm is burstable")
    end

    it "fails if the vm has more than one storage volume" do
      sd = StorageDevice.create(name: "vdb", total_storage_gib: 100, available_storage_gib: 100, vm_host_id: source_host.id)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 5, disk_index: 1, storage_device_id: sd.id)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "Vm must have a single storage volume")
    end

    it "fails if the vm_host does not have sufficient cores" do
      vm_host.update(used_cores: vm_host.total_cores)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost does not have sufficient space for the Vm")
    end

    it "fails if the vm_host does not have sufficient memory" do
      vm_host.update(used_hugepages_1g: vm_host.total_hugepages_1g)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost does not have sufficient space for the Vm")
    end

    it "fails if the vm_host does not have sufficient storage" do
      vm_host.storage_devices_dataset.update(available_storage_gib: 0)
      expect { described_class.assemble(vm, vm_host) }.to raise_error(RuntimeError, "VmHost does not have sufficient space for the Vm")
    end

    it "creates a remote storage server, renames the old vm, creates a new vm, and creates a MoveVm strand" do
      old_volume = vm.vm_storage_volumes.first
      vm_host

      st = nil
      expect { st = described_class.assemble(vm, vm_host) }.to change(RemoteStorageServer, :count).from(0).to(1)
        .and not_change { Sshable.count }

      expect(vm.reload.prevent_destroy_set?).to be true

      rss = RemoteStorageServer.first
      expect(rss.source_vm_storage_volume_id).to eq(old_volume.id)

      expect(vm.name).to eq("moving-with-#{rss.ubid}")

      new_vm = Vm.first(name: "old-vm")
      expect(new_vm.id).not_to eq(vm.id)
      expect(new_vm.project_id).to eq(vm.project_id)
      expect(new_vm.location_id).to eq(vm.location_id)
      expect(new_vm.unix_user).to eq(vm.unix_user)
      expect(new_vm.boot_image).to eq(vm.boot_image)
      expect(new_vm.arch).to eq(vm.arch)
      expect(new_vm.ip4_enabled).to eq(vm.ip4_enabled)

      new_volume = new_vm.vm_storage_volumes.first
      expect(new_volume.size_gib).to eq(old_volume.size_gib)
      expect(new_volume.remote_storage_server_id).to eq(rss.id)
      expect(new_vm.strand.stack.first["force_host_id"]).to eq(vm_host.id)
      expect(new_vm.prevent_destroy_set?).to be true

      expect(st.parent_id).to be_nil
      expect(st.prog).to eq("Vm::Metal::MoveVm")
      expect(st.label).to eq("start")
      expect(st.stack.first["subject_id"]).to eq(new_vm.id)
      expect(st.stack.first["remote_storage_server_id"]).to eq(rss.id)
      expect(st.stack.first["old_vm_id"]).to eq vm.id
      expect(st.stack.first["unset_prevent_destroy"]).to be true
    end

    it "creates an sshable if current vm has sshable" do
      parent_st = Strand.create(prog: "Test::MoveVm", label: "start")
      old_sshable = Sshable.create_with_id(vm, unix_user: "test", host: "t_#{vm.id}", raw_private_key_1: SshKey.generate.keypair)
      old_volume = vm.vm_storage_volumes.first
      vm_host
      vm.incr_prevent_destroy

      st = nil
      expect { st = described_class.assemble(vm, vm_host, parent_id: parent_st.id) }.to change(RemoteStorageServer, :count).from(0).to(1)
        .and change { Sshable.count }.from(3).to(4)

      expect(vm.reload.prevent_destroy_set?).to be true

      rss = RemoteStorageServer.first
      expect(rss.source_vm_storage_volume_id).to eq(old_volume.id)

      expect(vm.name).to eq("moving-with-#{rss.ubid}")

      new_vm = Vm.first(name: "old-vm")
      expect(new_vm.id).not_to eq(vm.id)
      expect(new_vm.project_id).to eq(vm.project_id)
      expect(new_vm.location_id).to eq(vm.location_id)
      expect(new_vm.unix_user).to eq(vm.unix_user)
      expect(new_vm.boot_image).to eq(vm.boot_image)
      expect(new_vm.arch).to eq(vm.arch)
      expect(new_vm.ip4_enabled).to eq(vm.ip4_enabled)

      new_volume = new_vm.vm_storage_volumes.first
      expect(new_volume.size_gib).to eq(old_volume.size_gib)
      expect(new_volume.remote_storage_server_id).to eq(rss.id)
      expect(new_vm.strand.stack.first["force_host_id"]).to eq(vm_host.id)
      expect(new_vm.prevent_destroy_set?).to be true

      new_sshable = Sshable[new_vm.id]
      expect(new_sshable.unix_user).to eq old_sshable.unix_user
      expect(new_sshable.raw_private_key_1).to eq old_sshable.raw_private_key_1

      expect(st.parent_id).to eq(parent_st.id)
      expect(st.prog).to eq("Vm::Metal::MoveVm")
      expect(st.label).to eq("start")
      expect(st.stack.first["subject_id"]).to eq(new_vm.id)
      expect(st.stack.first["remote_storage_server_id"]).to eq(rss.id)
      expect(st.stack.first["old_vm_id"]).to eq vm.id
      expect(st.stack.first["unset_prevent_destroy"]).to be false
    end
  end

  describe "instance methods" do
    subject(:nx) { described_class.new(st) }

    let(:target_host) {
      vm_host = create_vm_host(location_id: Location::HETZNER_FSN1_ID)
      VhostBlockBackend.create(version: "0.5.1", allocation_weight: 100, vm_host_id: vm_host.id)
      vm_host
    }

    let(:new_vm) {
      v = create_vm(vm_host_id: target_host.id, name: "new-vm")
      Strand.create_with_id(v.id, prog: "Vm::Metal::Nexus", label: "start")
      sd = StorageDevice.create(vm_host_id: target_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 50)
      VmStorageVolume.create(vm_id: v.id, boot: true, size_gib: 5, disk_index: 0, storage_device_id: sd.id)
      v
    }

    let(:rss_source_volume) {
      rss_source_vm = create_vm(vm_host_id: target_host.id, name: "rss-source-vm")
      Strand.create_with_id(rss_source_vm.id, prog: "Vm::Metal::Nexus", label: "stopped_by_admin")
      sd = StorageDevice.create(vm_host_id: target_host.id, name: "rss-sd", total_storage_gib: 10, available_storage_gib: 10)
      VmStorageVolume.create(vm_id: rss_source_vm.id, boot: true, size_gib: 5, disk_index: 0, storage_device_id: sd.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "rss-src").id)
    }

    # Built via .assemble (rather than RemoteStorageServer.create) so that it has
    # its own Strand row, which incr_destroy/destroy_set? rely on.
    let(:rss) { Prog::Storage::RemoteStorageServer::Nexus.assemble(rss_source_volume.id).subject }

    let(:st) {
      Strand.create(prog: "Vm::Metal::MoveVm", label: "start", stack: [{"subject_id" => new_vm.id, "remote_storage_server_id" => rss.id}])
    }

    describe "#start" do
      it "registers a deadline and hops to wait" do
        expect { nx.start }.to hop("wait")
        frame = st.stack.first
        expect(frame.fetch("deadline_target")).to be_nil
        expect(Time.new(frame["deadline_at"])).to be_within(5).of(Time.now + 60 * 60)
      end
    end

    describe "#wait" do
      it "naps if the new vm's strand is not in wait" do
        expect { nx.wait }.to nap(30)
      end

      it "naps if the new vm's strand is at wait but its storage volume is not caught up" do
        new_vm.strand.update(label: "wait")
        new_vm.vm_storage_volumes.first.update(remote_storage_server_id: rss.id)
        expect { nx.wait }.to nap(30)
      end

      it "hops to destroy once the new vm is in wait and its storage volume is caught up" do
        new_vm.strand.update(label: "wait")
        expect { nx.wait }.to hop("destroy")
      end

      it "hops to destroy if cancel_move semaphore is set" do
        Semaphore.incr(st.id, "cancel_move")
        expect { nx.wait }.to hop("destroy")
      end
    end

    describe "#destroy" do
      it "destroys the remote storage server and pops" do
        new_vm.incr_prevent_destroy
        expect { nx.destroy }.to exit({"msg" => "vm moved"})
        expect(rss.destroy_set?(cached: false)).to be(true)
        expect(new_vm.prevent_destroy_set?(cached: false)).to be(false)
      end

      it "also removes prevent_destroy semaphore on old vm is it should unset" do
        rss_source_vm = rss_source_volume.vm
        rss_source_vm.incr_prevent_destroy
        new_vm.incr_prevent_destroy
        st = Strand.create(prog: "Vm::Metal::MoveVm", label: "start", stack: [{"subject_id" => new_vm.id, "remote_storage_server_id" => rss.id, "old_vm_id" => rss_source_vm.id, "unset_prevent_destroy" => true}])
        Semaphore.incr(st.id, "cancel_move")
        nx = described_class.new(st)
        expect { nx.destroy }.to exit({"msg" => "vm moved"})
        expect(rss.destroy_set?(cached: false)).to be(true)
        expect(rss_source_vm.prevent_destroy_set?(cached: false)).to be(false)
        expect(new_vm.prevent_destroy_set?(cached: false)).to be(false)
        expect(new_vm.destroy_set?(cached: false)).to be true
      end
    end
  end
end
