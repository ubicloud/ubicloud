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
      expect(st.label).to eq("start")

      frame = st.stack.first
      expect(frame).to include("vm_host_id" => vm_host.id, "markers" => [])
      expect(Strand.where(prog: "Storage::SetupVhostBlockBackend").count).to eq 1

      vm = Vm[frame["vm_id"]]
      expect(vm.location_id).to eq(vm_host.location_id)
      expect(vm.arch).to eq(vm_host.arch)
      expect(vm.display_size).to eq("standard-2")
    end

    it "allows using an existing project, and not starting vhost_block_backend strand if host already has suitable one" do
      project_id = Project.create(name: "move-vm-test").id
      VhostBlockBackend.create(version: "0.5.1", allocation_weight: 100, vm_host_id: vm_host.id)

      st = described_class.assemble(vm_host, project_id:)
      expect(st.prog).to eq("Test::MoveVm")
      expect(st.label).to eq("start")

      frame = st.stack.first
      expect(frame).to include("vm_host_id" => vm_host.id, "markers" => [])
      expect(Strand.where(prog: "Storage::SetupVhostBlockBackend").count).to eq 0

      vm = Vm[frame["vm_id"]]
      expect(vm.project_id).to eq(project_id)
      expect(vm.location_id).to eq(vm_host.location_id)
      expect(vm.arch).to eq(vm_host.arch)
      expect(vm.display_size).to eq("standard-2")
    end
  end

  describe "#start" do
    it "naps until the vm is running" do
      vm = create_vm(display_state: "creating")
      refresh_frame(prog, new_values: {"vm_id" => vm.id})
      expect { prog.start }.to nap(10)
    end

    it "writes marker files, records their checksums, prepares vm to move, and hops to move vm" do
      vm = create_vm(display_state: "running")
      Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "wait")
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "1.2.3.4")
      refresh_frame(prog, new_values: {"vm_id" => vm.id})

      expect(prog.vm_sshable).to receive(:_cmd).with("sudo mkdir -p /opt/markers")
      described_class::MARKER_COUNT.times do |i|
        expect(prog.vm_sshable).to receive(:_cmd)
          .with("head -c 1M /dev/urandom | sudo tee /opt/markers/marker-#{i} | sha256sum")
          .and_return("sha-#{i}  x\n")
      end

      expect { prog.start }.to hop("move_vm")
        .and change { vm.prepare_to_move_set?(cached: false) }.from(false).to(true)
        .and change { vm.stop_set?(cached: false) }.from(false).to(true)

      expect(prog.markers).to eq(Array.new(described_class::MARKER_COUNT) { |i| ["/opt/markers/marker-#{i}", "sha-#{i}"] })
    end
  end

  describe "#move_vm" do
    it "naps while the vm's strand hasn't reached stopped_by_admin" do
      vm = create_vm
      Strand.create_with_id(vm, prog: "Vm::Metal::Nexus", label: "wait")
      refresh_frame(prog, new_values: {"vm_id" => vm.id})
      expect { prog.move_vm }.to nap(10)
    end

    it "assembles Prog::Vm::Metal::MoveVm and stores the new vm id and move strand id" do
      vm = create_archive_ready_vm(name: "test-name", public_key: "a a")
      vm_host = vm.vm_host
      vm.incr_prepare_to_move
      vm.strand.update(label: "stopped_by_admin")
      vm.vm_host.update(total_cpus: 24)
      VhostBlockBackend.create(version: "0.5.1", allocation_weight: 100, vm_host_id: vm.vm_host_id)
      private_subnet = PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "1.1.1.0/26", state: "waiting", project_id: vm.project_id)
      Nic.create(private_subnet_id: private_subnet.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::", private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:00", encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579", name: "old-vm-nic",
        vm_id: vm.id, state: "active")

      ssh_key = SshKey.generate
      Sshable.create_with_id(vm, unix_user: "ubi", host: "t_#{vm.id}", raw_private_key_1: ssh_key.keypair)

      prog = described_class.new(Strand.create(prog: "Test::MoveVm", label: "move_vm", stack: [{"vm_host_id" => vm_host.id, "vm_id" => vm.id}]))
      expect { prog.move_vm }.to hop("wait_vm_moved")
        .and change { Sshable.count }.from(2).to(3)

      move_vm_strand = prog.strand.children.first
      expect(move_vm_strand.prog).to eq("Vm::Metal::MoveVm")
      expect(move_vm_strand.stack.first["subject_id"]).to eq(prog.new_vm_id)
      expect(prog.new_vm_id).not_to eq(vm.id)
    end
  end

  describe "#wait_vm_moved" do
    it "naps while the move child strand still exists" do
      Strand.create(prog: "Vm::Metal::MoveVm", label: "start", stack: [{}], parent_id: prog.strand.id, lease: Time.now + 100)
      expect { prog.wait_vm_moved }.to nap(120)
    end

    it "hops to verify_new_vm once the child strand no longer exists" do
      expect { prog.wait_vm_moved }.to hop("verify_new_vm")
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
      expect(prog.new_vm_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-0").and_return("sha-0  x\n")
      expect(prog.new_vm_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-1").and_return("sha-1  x\n")

      expect { prog.verify_new_vm }.to hop("destroy")
    end

    it "fails when a checksum doesn't match" do
      expect(prog.new_vm_sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/marker-0").and_return("wrong  x\n")

      expect { prog.verify_new_vm }.to hop("failed")
    end
  end

  describe "#destroy" do
    it "sets the destroy semaphore on both vms and hops to wait_resources_destroyed" do
      old_vm = create_vm
      new_vm = create_vm
      Strand.create_with_id(old_vm, prog: "Vm::Metal::Nexus", label: "wait")
      Strand.create_with_id(new_vm, prog: "Vm::Metal::Nexus", label: "wait")
      refresh_frame(prog, new_values: {"vm_id" => old_vm.id, "new_vm_id" => new_vm.id})

      expect { prog.destroy }.to hop("wait_resources_destroyed")

      expect(old_vm.destroy_set?(cached: false)).to be true
      expect(new_vm.destroy_set?(cached: false)).to be true
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
