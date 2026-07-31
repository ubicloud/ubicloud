# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::MoveVm do
  let(:vm_host) {
    create_vm_host(location_id: Location::HETZNER_FSN1_ID, total_cpus: 48, total_cores: 48,
      used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16)
  }

  let(:prog) {
    described_class.new(described_class.assemble(vm_host))
  }

  describe ".assemble" do
    it "creates a project and VM in the vm_host's location/arch and stages the strand" do
      st = described_class.assemble(vm_host)
      expect(st.prog).to eq("Test::MoveVm")
      expect(st.label).to eq("wait_vm_running")

      frame = st.stack.first
      expect(frame).to include("vm_host_id" => vm_host.id, "markers" => [])

      vm = Vm[frame["vm_id"]]
      expect(vm.location_id).to eq(vm_host.location_id)
      expect(vm.arch).to eq(vm_host.arch)
      expect(vm.display_size).to eq("standard-2")
    end
  end

  describe "#wait_vm_running" do
    let(:vm) { create_vm(display_state: "creating") }

    before { refresh_frame(prog, new_values: {"vm_id" => vm.id}) }

    it "naps while the vm is not running" do
      expect { prog.wait_vm_running }.to nap(10)
    end

    it "hops to write_markers once the vm is running" do
      vm.update(display_state: "running")
      expect { prog.wait_vm_running }.to hop("write_markers")
    end
  end

  describe "#write_markers" do
    it "writes marker files, records their checksums, and hops to prepare_to_move" do
      vm = create_vm(display_state: "running")
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "1.2.3.4")
      refresh_frame(prog, new_values: {"vm_id" => vm.id})

      expect(prog.sshable).to receive(:_cmd).with("sudo mkdir -p /opt/markers")
      described_class::MARKER_COUNT.times do |i|
        expect(prog.sshable).to receive(:_cmd)
          .with("head -c 1M /dev/urandom | sudo tee /opt/markers/marker-#{i} | sha256sum")
          .and_return("sha-#{i}  x\n")
      end

      expect { prog.write_markers }.to hop("prepare_to_move")

      expect(prog.markers).to eq(Array.new(described_class::MARKER_COUNT) { |i| ["/opt/markers/marker-#{i}", "sha-#{i}"] })
    end
  end

  describe "#prepare_to_move" do
    it "sets the prepare_to_move and stop semaphores and hops to wait_stopped_by_admin" do
      vm = create_vm
      Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "wait")
      refresh_frame(prog, new_values: {"vm_id" => vm.id})

      expect { prog.prepare_to_move }.to hop("wait_stopped_by_admin")

      expect(vm.reload.prepare_to_move_set?).to be true
      expect(vm.reload.stop_set?).to be true
    end
  end

  describe "#wait_stopped_by_admin" do
    let(:vm) {
      vm = create_vm
      Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "wait")
      vm
    }

    before { refresh_frame(prog, new_values: {"vm_id" => vm.id}) }

    it "naps while the vm's strand hasn't reached stopped_by_admin" do
      expect { prog.wait_stopped_by_admin }.to nap(10)
    end

    it "hops to move_vm once the vm's strand reaches stopped_by_admin" do
      vm.strand.update(label: "stopped_by_admin")
      expect { prog.wait_stopped_by_admin }.to hop("move_vm")
    end
  end

  describe "#move_vm" do
    it "assembles Prog::Vm::Metal::MoveVm and stores the new vm id and move strand id" do
      StorageDevice.create(name: "target-vda", total_storage_gib: 100, available_storage_gib: 100, vm_host_id: vm_host.id)

      project = Project.create(name: "move-vm-test-project")
      source_host = create_vm_host(location_id: Location::HETZNER_FSN1_ID)
      ready_vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, vm_host_id: source_host.id, name: "old-vm")
      private_subnet = PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: project.id)
      Nic.create(private_subnet_id: private_subnet.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::", private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00", encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "old-vm-nic",
        vm_id: ready_vm.id, state: "active")
      vbb = create_vhost_block_backend(vm_host_id: source_host.id)
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: source_host.id)
      VmStorageVolume.create(vm_id: ready_vm.id, boot: true, size_gib: 40, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "src").id,
        vring_workers: 1, track_written: true)
      Strand.create_with_id(ready_vm.id, prog: "Vm::Metal::Nexus", label: "stopped_by_admin")
      ready_vm.incr_prepare_to_move

      refresh_frame(prog, new_values: {"vm_id" => ready_vm.id})

      expect { prog.move_vm }.to hop("wait_move_vm")

      move_vm_strand = Strand[prog.move_vm_strand_id]
      expect(move_vm_strand.prog).to eq("Vm::Metal::MoveVm")
      expect(move_vm_strand.stack.first["subject_id"]).to eq(prog.new_vm_id)
      expect(prog.new_vm_id).not_to eq(ready_vm.id)
    end
  end

  describe "#wait_move_vm" do
    it "naps while the move strand still exists" do
      move_strand = Strand.create(prog: "Vm::Metal::MoveVm", label: "start", stack: [{}])
      refresh_frame(prog, new_values: {"move_vm_strand_id" => move_strand.id})
      expect { prog.wait_move_vm }.to nap(10)
    end

    it "hops to verify_new_vm once the move strand has popped" do
      refresh_frame(prog, new_values: {"move_vm_strand_id" => Strand.generate_uuid})
      expect { prog.wait_move_vm }.to hop("verify_new_vm")
    end
  end

  describe "#verify_new_vm" do
    let(:new_vm) {
      vm = create_vm(display_state: "running")
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "5.6.7.8")
      vm
    }

    before do
      refresh_frame(prog, new_values: {
        "new_vm_id" => new_vm.id,
        "markers" => [["/opt/markers/marker-0", "sha-0"], ["/opt/markers/marker-1", "sha-1"]],
      })
    end

    it "hops to destroy_vms when all checksums match" do
      expect(prog.new_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-0").and_return("sha-0  x\n")
      expect(prog.new_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-1").and_return("sha-1  x\n")

      expect { prog.verify_new_vm }.to hop("destroy_vms")
    end

    it "fails when a checksum doesn't match" do
      expect(prog.new_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-0").and_return("wrong  x\n")

      expect { prog.verify_new_vm }.to hop("failed")
    end
  end

  describe "#destroy_vms" do
    it "sets the destroy semaphore on both vms and hops to wait_resources_destroyed" do
      old_vm = create_vm
      new_vm = create_vm
      Strand.create_with_id(old_vm, prog: "Vm::Metal::Nexus", label: "wait")
      Strand.create_with_id(new_vm, prog: "Vm::Metal::Nexus", label: "wait")
      refresh_frame(prog, new_values: {"vm_id" => old_vm.id, "new_vm_id" => new_vm.id})

      expect { prog.destroy_vms }.to hop("wait_resources_destroyed")

      expect(old_vm.reload.destroy_set?).to be true
      expect(new_vm.reload.destroy_set?).to be true
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps while either vm still exists" do
      old_vm = create_vm
      refresh_frame(prog, new_values: {"vm_id" => old_vm.id, "new_vm_id" => Vm.generate_uuid})
      expect { prog.wait_resources_destroyed }.to nap(10)
    end

    it "pops once both vms are gone" do
      refresh_frame(prog, new_values: {"vm_id" => Vm.generate_uuid, "new_vm_id" => Vm.generate_uuid})
      expect { prog.wait_resources_destroyed }.to exit({"msg" => "Test completed successfully"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { prog.failed }.to nap(15)
    end
  end
end
