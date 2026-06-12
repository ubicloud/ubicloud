# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::CreateVersionMetal do
  subject(:prog) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-mi-project") }
  let(:vm_host) { create_vm_host }
  let(:vhost_block_backend) { create_vhost_block_backend(allocation_weight: 50, vm_host_id: vm_host.id) }
  let(:source_vm) {
    vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
    Strand.create_with_id(vm, prog: "Vm::Nexus", label: "stopped")
    sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
    VmStorageVolume.create(
      vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
      storage_device_id: sd.id, vhost_block_backend_id: vhost_block_backend.id,
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "test-source-kek").id,
      vring_workers: 1, track_written: true,
    )
    vm
  }
  let(:source_vol) { source_vm.vm_storage_volumes.first }
  let(:source_kek) { source_vol.key_encryption_key_1 }
  let(:machine_image) { MachineImage.create(name: "test-image", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID) }
  let(:store) {
    MachineImageStore.create(
      project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
      provider: "r2", region: "auto", endpoint: "https://r2.example.com/",
      bucket: "test-bucket", access_key: "ak", secret_key: "sk",
    )
  }
  let(:mi_version) { MachineImageVersion.create(machine_image_id: machine_image.id, version: "1.0", actual_size_mib: nil) }
  let(:archive_kek) { StorageKeyEncryptionKey.create_random(auth_data: "archive-kek") }
  let(:mi_version_metal) {
    MachineImageVersionMetal.create_with_id(mi_version,
      status: "creating", archive_kek_id: archive_kek.id, store_id: store.id,
      store_prefix: "#{project.ubid}/#{machine_image.ubid}/1.0")
  }
  let(:strand) {
    Strand.create_with_id(mi_version_metal,
      prog: "MachineImage::CreateVersionMetal",
      label: "archive_from_vm",
      stack: [{
        "source_vm_id" => source_vm.id,
        "destroy_source_after" => false,
        "set_as_latest" => true,
      }])
  }

  describe ".assemble_from_vm" do
    it "fails when source VM arch does not match machine image arch" do
      machine_image.update(arch: "arm64")
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", source_vm, store)
      }.to raise_error("Source VM arch (x64) does not match machine image arch (arm64)")
    end

    it "fails when source VM is not a metal VM" do
      vm_without_host = create_vm(project_id: project.id, name: "vm-without-host")
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", vm_without_host, store)
      }.to raise_error("Source VM must be a metal VM")
    end

    it "fails when source VM has more than one storage volume" do
      VmStorageVolume.create(
        vm_id: source_vm.id, boot: false, size_gib: 10, disk_index: 1,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: source_vol.vhost_block_backend_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "extra").id,
        vring_workers: 1,
      )
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", source_vm.reload, store)
      }.to raise_error("Source VM must have only one storage volume")
    end

    it "fails when source VM is not stopped" do
      running_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "running-vm")
      VmStorageVolume.create(
        vm_id: running_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: source_vol.vhost_block_backend_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "x").id,
        vring_workers: 1,
      )
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", running_vm, store)
      }.to raise_error("Source VM must be stopped")
    end

    it "fails when source VM's storage volume doesn't support machine images" do
      untracked_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "vm-untracked")
      Strand.create_with_id(untracked_vm, prog: "Vm::Nexus", label: "stopped")
      VmStorageVolume.create(
        vm_id: untracked_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: source_vol.vhost_block_backend_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "y").id,
        vring_workers: 1,
      )
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", untracked_vm, store)
      }.to raise_error("Source VM's storage volume doesn't support machine images")
    end

    it "fails when source VM's storage volume is not encrypted" do
      unencrypted_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "unencrypted-vm")
      Strand.create_with_id(unencrypted_vm, prog: "Vm::Nexus", label: "stopped")
      VmStorageVolume.create(
        vm_id: unencrypted_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: source_vol.vhost_block_backend_id,
        vring_workers: 1, track_written: true,
      )
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", unencrypted_vm, store)
      }.to raise_error("Source VM's storage volume must be encrypted")
    end

    it "fails when source VM's storage volume is larger than machine_image_max_size_gib" do
      source_vol.update(size_gib: Config.machine_image_max_size_gib + 1)
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", source_vm, store)
      }.to raise_error("Source VM's storage volume is larger than #{Config.machine_image_max_size_gib} GiB")
    end

    it "creates a version with actual_size_mib=nil and a strand at archive_from_vm" do
      s = described_class.assemble_from_vm(machine_image, "2.0", source_vm, store, destroy_source_after: true)

      mv = MachineImageVersion[s.id]
      expect(mv.actual_size_mib).to be_nil
      expect(mv.metal).to have_attributes(status: "creating", store_id: store.id,
        store_prefix: "#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(s.prog).to eq("MachineImage::CreateVersionMetal")
      expect(s.label).to eq("archive_from_vm")
      expect(s.stack.first.values_at("source_vm_id", "destroy_source_after", "set_as_latest"))
        .to eq([source_vm.id, true, true])
    end

    it "uses the defaulted version label in store_prefix and archive_kek auth_data" do
      s = described_class.assemble_from_vm(machine_image, nil, source_vm, store)
      mv = MachineImageVersion[s.id]
      expect(mv.version).to match(/\A\d{14}\z/)
      expect(mv.metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/#{mv.version}")
      expect(mv.metal.archive_kek.auth_data).to eq("machine_image_version_#{mv.ubid}_#{mv.version}")
    end
  end

  describe ".assemble_from_url" do
    it "fails when no vm host with archive support exists in location" do
      expect {
        described_class.assemble_from_url(machine_image, "1.0", "https://x/img", "abc", store)
      }.to raise_error("no vm host with archive support found in location")
    end

    it "creates a version and a strand at archive_from_url, recording vbb host" do
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      s = described_class.assemble_from_url(machine_image, "2.0", "https://x/img", "abc", store, set_as_latest: false)

      mv = MachineImageVersion[s.id]
      expect(mv.actual_size_mib).to be_nil
      expect(mv.metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(s.label).to eq("archive_from_url")
      expect(s.stack.first.values_at("url", "sha256sum", "vm_host_id", "vhost_block_backend_version", "set_as_latest"))
        .to eq(["https://x/img", "abc", vm_host.id, vbb.version, false])
    end

    it "selects only from backends that support archive" do
      create_vhost_block_backend(version: "v0.3.0", allocation_weight: 5000, vm_host_id: vm_host.id)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id)

      s = described_class.assemble_from_url(machine_image, "2.0", "https://x/img", "abc", store)

      expect(s.stack.first["vhost_block_backend_version"]).to eq(vbb.version)
    end
  end

  describe "#archive_from_vm" do
    let(:sshable) { source_vm.vm_host.sshable }
    let(:daemon_name) { "archive_#{mi_version.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{mi_version.ubid}.json" }

    before do
      allow(prog).to receive_messages(archive_params_json_for_vm: "{\"field\":\"value\"}", source_vm:)
    end

    it "reads physical and logical size from stats and hops to finish on Succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}").and_return('{"physical_size_bytes": 10485760, "logical_size_bytes": 1073741824}')
      expect(sshable).to receive(:d_clean).with(daemon_name)

      expect { prog.archive_from_vm }.to hop("finish")
      expect(strand.stack.first["physical_size_bytes"]).to eq(10485760)
      expect(strand.stack.first["logical_size_bytes"]).to eq(1073741824)
    end

    it "restarts daemon on Failed" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive_from_vm }.to nap(60)
    end

    it "starts daemon on NotStarted" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, "vda", 0, vhost_block_backend.version, stats_path,
        stdin: "{\"field\":\"value\"}", log: false)
      expect { prog.archive_from_vm }.to nap(30)
    end

    it "naps on InProgress" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("InProgress")
      expect { prog.archive_from_vm }.to nap(30)
    end

    it "logs and naps on unknown status" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("UnknownStatus").twice
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: UnknownStatus")
      expect { prog.archive_from_vm }.to nap(60)
    end
  end

  describe "#archive_from_url" do
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_#{mi_version.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{mi_version.ubid}.json" }
    let(:url_strand) {
      Strand.create_with_id(mi_version_metal,
        prog: "MachineImage::CreateVersionMetal", label: "archive_from_url",
        stack: [{
          "url" => "https://x/img", "sha256sum" => "abc",
          "vm_host_id" => vm_host.id, "vhost_block_backend_version" => "v0.4.1",
          "set_as_latest" => true,
        }])
    }
    let(:url_prog) { described_class.new(url_strand) }

    before do
      allow(url_prog).to receive_messages(archive_params_json_for_url: "{\"field\":\"value\"}", vm_host:)
    end

    it "reads stats and hops to finish on Succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}").and_return('{"physical_size_bytes": 1, "logical_size_bytes": 2}')
      expect(sshable).to receive(:d_clean).with(daemon_name)
      expect { url_prog.archive_from_url }.to hop("finish")
    end

    it "starts daemon with archive-url on NotStarted" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-url", "https://x/img", "abc", "v0.4.1", stats_path,
        stdin: "{\"field\":\"value\"}", log: false)
      expect { url_prog.archive_from_url }.to nap(30)
    end
  end

  describe "#finish" do
    before {
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1048576, "logical_size_bytes" => 100 * 1048576})
      allow(prog).to receive_messages(source_vm:, vm_host:)
      expect(vm_host.sshable).to receive(:_cmd).with("sudo rm -f /tmp/archive_stats_#{mi_version.ubid}.json")
    }

    it "marks version ready, sets archive_size_mib + actual_size_mib from stats, creates billing" do
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is ready"})

      mi_version_metal.reload
      mi_version.reload
      expect(mi_version_metal.status).to eq("ready")
      expect(mi_version_metal.archive_size_mib).to eq(10)
      expect(mi_version.actual_size_mib).to eq(100)
      expect(BillingRecord.where(resource_id: mi_version_metal.id).count).to eq(1)
    end

    it "kicks the source VM destroy when destroy_source_after is set" do
      refresh_frame(prog, new_values: {
        "physical_size_bytes" => 10 * 1048576, "logical_size_bytes" => 100 * 1048576,
        "destroy_source_after" => true,
      })
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is ready"})
      expect(source_vm.reload.destroy_set?).to be true
    end

    it "sets latest_version_id when set_as_latest is true" do
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is ready"})
      expect(machine_image.reload.latest_version.id).to eq(mi_version_metal.id)
    end

    it "skips latest_version_id assignment when set_as_latest is false" do
      refresh_frame(prog, new_values: {
        "physical_size_bytes" => 10 * 1048576, "logical_size_bytes" => 100 * 1048576,
        "set_as_latest" => false,
      })
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is ready"})
      expect(machine_image.reload.latest_version_id).to be_nil
    end
  end
end
