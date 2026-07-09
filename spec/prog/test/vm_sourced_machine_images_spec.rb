# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmSourcedMachineImages do
  before { create_vhost_block_backend(vm_host_id: create_vm_host.id) }

  let(:prog) {
    described_class.new(described_class.assemble(location_id: Location::HETZNER_FSN1_ID, arch: "x64"))
  }
  let(:starting_vm) {
    vm = create_vm(display_state: "creating")
    Strand.create_with_id(vm, prog: "Vm::Nexus", label: "start")
    vm
  }

  describe ".assemble" do
    it "creates the project + machine image + burstable-1 VM and stages the strand" do
      st = described_class.assemble(location_id: Location::HETZNER_FSN1_ID, arch: "x64")
      expect(st.prog).to eq("Test::VmSourcedMachineImages")
      expect(st.label).to eq("wait_initial_vm_running")
      frame = st.stack.first
      expect(frame).to include("round" => 1, "markers" => [], "machine_image_version_ids" => [])
      vm = Vm[frame["vm_id"]]
      expect(vm.display_size).to eq("burstable-1")
      expect(vm.project_id).to eq(frame["project_id"])
      expect(MachineImage[frame["machine_image_id"]].project_id).to eq(frame["project_id"])
    end
  end

  describe "#wait_initial_vm_running" do
    before { refresh_frame(prog, new_values: {"vm_id" => starting_vm.id}) }

    it "naps while the vm is not running" do
      expect { prog.wait_initial_vm_running }.to nap(10)
    end

    it "hops to write_markers_and_stop once the vm is running" do
      starting_vm.update(display_state: "running")
      starting_vm.strand.update(label: "wait")
      expect { prog.wait_initial_vm_running }.to hop("write_markers_and_stop")
    end
  end

  describe "#wait_source_vm_stopped" do
    before { refresh_frame(prog, new_values: {"vm_id" => starting_vm.id}) }

    it "naps while the vm is not stopped" do
      expect { prog.wait_source_vm_stopped }.to nap(10)
    end

    it "hops to capture_machine_image once the vm is stopped" do
      starting_vm.strand.update(label: "stopped")
      expect { prog.wait_source_vm_stopped }.to hop("capture_machine_image")
    end
  end

  describe "#wait_vm_from_machine_image_running" do
    before { refresh_frame(prog, new_values: {"vm_id" => starting_vm.id}) }

    it "naps while the vm is not running" do
      expect { prog.wait_vm_from_machine_image_running }.to nap(10)
    end

    it "hops to verify_markers once the vm is running" do
      starting_vm.update(display_state: "running")
      starting_vm.strand.update(label: "wait")
      expect { prog.wait_vm_from_machine_image_running }.to hop("verify_markers")
    end
  end

  describe "#write_markers_and_stop" do
    it "writes 5 marker files, appends [name, sha] pairs, and stops the VM" do
      vm = create_vm(display_state: "running")
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "1.2.3.4")
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "wait")
      refresh_frame(prog, new_values: {"vm_id" => vm.id, "round" => 2,
                                       "markers" => [["/path/to/prev/marker", "sha256-of-prev-marker"]]})

      expect(prog.sshable).to receive(:_cmd).with("sudo mkdir -p /opt/markers")
      5.times do |i|
        expect(prog.sshable).to receive(:_cmd).with("head -c 1M /dev/urandom | sudo tee /opt/markers/round-2-marker-#{i} | sha256sum").and_return("aaaa  x\n")
      end

      expect { prog.write_markers_and_stop }.to hop("wait_source_vm_stopped")

      expect(prog.markers).to eq([
        ["/path/to/prev/marker", "sha256-of-prev-marker"],
        *Array.new(5) { |i| ["/opt/markers/round-2-marker-#{i}", "aaaa"] },
      ])
      expect(vm.reload.stop_set?).to be(true)
    end
  end

  describe "#capture_machine_image" do
    let(:source_vm) {
      vm = create_archive_ready_vm(project_id: Project.create(name: "src").id)
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "1.2.3.4")
      vm
    }

    it "captures the source VM as v<round> and appends the miv id" do
      svc = Project.create(name: "svc")
      allow(Config).to receive(:machine_images_service_project_id).and_return(svc.id)
      store = MachineImageStore.create(project_id: svc.id, location_id: Location::HETZNER_FSN1_ID,
        provider: "r2", region: "auto", endpoint: "e", bucket: "b", access_key: "a", secret_key: "s")
      prev_metal = create_machine_image_version_metal(project_id: prog.project_id, machine_image_store_id: store.id)
      refresh_frame(prog, new_values: {"vm_id" => source_vm.id, "round" => 2,
                                       "machine_image_version_ids" => [prev_metal.id]})

      expect { prog.capture_machine_image }.to hop("wait_machine_image_captured")

      expect(prog.machine_image_version_ids.size).to eq(2)
      expect(prog.machine_image_version_ids.first).to eq(prev_metal.id)
      new_metal = MachineImageVersionMetal[prog.machine_image_version_ids.last]
      expect(new_metal.machine_image_version.machine_image_id).to eq(prog.machine_image_id)
    end
  end

  describe "#wait_machine_image_captured" do
    let(:metal) { create_machine_image_version_metal }

    before { refresh_frame(prog, new_values: {"machine_image_version_ids" => [metal.id]}) }

    it "hops to wait_source_vm_destroyed when ready" do
      metal.update(status: "ready")
      expect { prog.wait_machine_image_captured }.to hop("wait_source_vm_destroyed")
    end

    it "fails when the version failed" do
      metal.update(status: "failed")
      expect { prog.wait_machine_image_captured }.to hop("failed")
    end

    it "naps while still creating" do
      metal.update(status: "creating")
      expect { prog.wait_machine_image_captured }.to nap(15)
    end
  end

  describe "#wait_source_vm_destroyed" do
    it "naps while the source VM still exists" do
      vm = create_vm
      refresh_frame(prog, new_values: {"vm_id" => vm.id})
      expect { prog.wait_source_vm_destroyed }.to nap(10)
    end

    it "hops to create_vm_from_machine_image once the source VM is gone" do
      destroyed_vm_id = Vm.generate_uuid
      refresh_frame(prog, new_values: {"vm_id" => destroyed_vm_id})
      expect { prog.wait_source_vm_destroyed }.to hop("create_vm_from_machine_image")
    end
  end

  describe "#create_vm_from_machine_image" do
    it "assembles a new VM whose boot volume points at the MI's latest version" do
      mi = MachineImage[prog.machine_image_id]
      miv = create_machine_image_version_metal(project_id: mi.project_id, machine_image_id: mi.id, version: "v1").machine_image_version
      mi.update(latest_version_id: miv.id)
      expect { prog.create_vm_from_machine_image }.to hop("wait_vm_from_machine_image_running")
      expect(Vm[prog.vm_id].vm_storage_volumes_dataset.first(boot: true).machine_image_version_id).to eq(miv.id)
    end
  end

  describe "#verify_markers" do
    let(:target_vm) {
      vm = create_vm(display_state: "running")
      Sshable.create_with_id(vm.id, unix_user: "ubi", host: "1.2.3.4")
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "wait")
      vm
    }

    before do
      refresh_frame(prog, new_values: {"vm_id" => target_vm.id,
                                       "markers" => [["/opt/markers/m0", "sha0"], ["/opt/markers/m1", "sha1"]],
                                       "round" => 1})
    end

    it "hops back to write_markers_and_stop when markers match and there are more rounds" do
      expect(prog.sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/m0").and_return("sha0  x\n")
      expect(prog.sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/m1").and_return("sha1  x\n")
      expect { prog.verify_markers }.to hop("write_markers_and_stop")
      expect(prog.round).to eq(2)
    end

    it "starts the destroy chain on the last round" do
      miv_metals = Array.new(2) { create_machine_image_version_metal }
      refresh_frame(prog, new_values: {"round" => 2, "machine_image_version_ids" => miv_metals.map(&:id)})
      expect(prog.sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/m0").and_return("sha0  x\n")
      expect(prog.sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/m1").and_return("sha1  x\n")
      expect { prog.verify_markers }.to hop("wait_resources_destroyed")
      expect(target_vm.reload.destroy_set?).to be(true)
      expect(miv_metals.map { it.reload.destroy_set? }).to all(be(true))
    end

    it "fails when the sha256 doesn't match" do
      expect(prog.sshable).to receive(:_cmd).with("sudo sha256sum /opt/markers/m0").and_return("wrong  x\n")
      expect { prog.verify_markers }.to hop("failed")
    end
  end

  describe "#wait_resources_destroyed" do
    before { refresh_frame(prog, new_values: {"vm_id" => Vm.generate_uuid, "machine_image_version_ids" => []}) }

    it "pops when the vm is gone and no MIV metals remain" do
      expect { prog.wait_resources_destroyed }.to exit({"msg" => "Test completed successfully"})
    end

    it "naps while any MIV metal still exists" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_ids" => [metal.id]})
      expect { prog.wait_resources_destroyed }.to nap(10)
    end

    it "naps while the vm still exists" do
      refresh_frame(prog, new_values: {"vm_id" => starting_vm.id})
      expect { prog.wait_resources_destroyed }.to nap(10)
    end
  end

  describe "#failed" do
    it "naps" do
      expect { prog.failed }.to nap(15)
    end
  end
end
