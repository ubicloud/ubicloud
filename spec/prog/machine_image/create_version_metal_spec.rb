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
      vring_workers: 1,
    )
    vm
  }
  let(:source_vol) { source_vm.vm_storage_volumes.first }
  let(:source_kek) { source_vol.key_encryption_key_1 }
  let(:machine_image) { MachineImage.create(name: "test-image", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID) }
  let(:store) {
    MachineImageStore.create(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      provider: "minio",
      region: "eu",
      endpoint: "https://minio.example.com/",
      bucket: "test-bucket",
      access_key: "test-access-key",
      secret_key: "test-secret-key",
    )
  }
  let(:mi_version) {
    MachineImageVersion.create(
      machine_image_id: machine_image.id,
      version: "1.0",
      actual_size_mib: 5120,
    )
  }
  let(:archive_kek) { StorageKeyEncryptionKey.create_random(auth_data: "target-kek") }
  let(:mi_version_metal) {
    MachineImageVersionMetal.create_with_id(
      mi_version,
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix: "#{project.ubid}/#{machine_image.ubid}/1.0",
    )
  }
  let(:strand) {
    Strand.create_with_id(
      mi_version_metal,
      prog: "MachineImage::CreateVersionMetal",
      label: "archive",
      stack: [{
        "source_vm_id" => source_vm.id,
        "destroy_source_after" => false,
      }],
    )
  }

  describe ".assemble" do
    it "fails when source VM is not a metal VM" do
      vm_without_host = create_vm(project_id: project.id, name: "vm-without-host")

      expect {
        described_class.assemble(machine_image, "1.0", vm_without_host, store)
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
        described_class.assemble(machine_image, "1.0", source_vm.reload, store)
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
        described_class.assemble(machine_image, "1.0", running_vm, store)
      }.to raise_error("Source VM must be stopped")
    end

    it "fails when source VM backend does not support archive" do
      old_backend = create_vhost_block_backend(version: "v0.3.0", allocation_weight: 0, vm_host_id: vm_host.id)
      old_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "vm-with-old-ubiblk")
      Strand.create_with_id(old_vm, prog: "Vm::Nexus", label: "stopped")
      VmStorageVolume.create(
        vm_id: old_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: old_backend.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "y").id,
        vring_workers: 1,
      )

      expect {
        described_class.assemble(machine_image, "1.0", old_vm, store)
      }.to raise_error("Source VM's vhost block backend must support archive")
    end

    it "fails when source VM's storage volume is not encrypted" do
      unencrypted_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "unencrypted-vm")
      Strand.create_with_id(unencrypted_vm, prog: "Vm::Nexus", label: "stopped")
      VmStorageVolume.create(
        vm_id: unencrypted_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id, vhost_block_backend_id: source_vol.vhost_block_backend_id,
        vring_workers: 1,
      )

      expect {
        described_class.assemble(machine_image, "1.0", unencrypted_vm, store)
      }.to raise_error("Source VM's storage volume must be encrypted")
    end

    it "fails when source VM has no vhost block backend" do
      no_backend_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "vm-with-no-vhost-backend")
      Strand.create_with_id(no_backend_vm, prog: "Vm::Nexus", label: "stopped")
      VmStorageVolume.create(
        vm_id: no_backend_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: source_vol.storage_device_id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "z").id,
      )

      expect {
        described_class.assemble(machine_image, "1.0", no_backend_vm, store)
      }.to raise_error("Source VM's vhost block backend must support archive")
    end

    it "creates a machine image version, its metal instance & archive_kek, and strand" do
      strand = described_class.assemble(machine_image, "2.0", source_vm, store, destroy_source_after: true)

      mi_version = MachineImageVersion[strand.id]
      expect(mi_version).not_to be_nil
      expect(mi_version.version).to eq("2.0")
      expect(mi_version.actual_size_mib).to eq(source_vm.storage_size_gib * 1024)

      mi_version_metal = mi_version.metal
      expect(mi_version_metal).not_to be_nil
      expect(mi_version_metal.enabled).to be false
      expect(mi_version_metal.store_id).to eq(store.id)
      expect(mi_version_metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(mi_version_metal.archive_kek).not_to be_nil

      expect(strand.prog).to eq("MachineImage::CreateVersionMetal")
      expect(strand.label).to eq("archive")
      expect(strand.stack.first["source_vm_id"]).to eq(source_vm.id)
      expect(strand.stack.first["destroy_source_after"]).to be true
      expect(strand.stack.first["set_as_latest"]).to be true
    end
  end

  describe "#archive" do
    let(:sshable) { source_vm.vm_host.sshable }
    let(:daemon_name) { "archive_#{mi_version.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{mi_version.ubid}.json" }

    before do
      allow(prog).to receive_messages(archive_params_json: "{\"field\":\"value\"}", source_vm:)
    end

    it "reads stats, cleans daemon and hops to finish when daemon succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}").and_return('{"physical_size_bytes": 10485760, "logical_size_bytes": 1073741824}')
      expect(sshable).to receive(:d_clean).with(daemon_name)

      expect { prog.archive }.to hop("finish")
      expect(strand.stack.first["archive_size_bytes"]).to eq(10485760)
    end

    it "restarts daemon when it failed" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive }.to nap(60)
    end

    it "starts daemon when status is NotStarted" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, "vda", 0, vhost_block_backend.version, stats_path,
        stdin: "{\"field\":\"value\"}", log: false)

      expect { prog.archive }.to nap(30)
    end

    it "naps when daemon is still running" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("InProgress")

      expect { prog.archive }.to nap(30)
    end

    it "handles unexpected daemon status" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("UnknownStatus")
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: UnknownStatus")

      expect { prog.archive }.to nap(60)
    end
  end

  describe "#finish" do
    before {
      refresh_frame(prog, new_values: {"archive_size_bytes" => 10 * 1024 * 1024})
      allow(prog).to receive(:source_vm).and_return(source_vm)
      expect(source_vm.vm_host.sshable).to receive(:_cmd).with("sudo rm -f /tmp/archive_stats_#{mi_version.ubid}.json")
    }

    it "enables machine image version metal and sets archive size" do
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is created and enabled"})

      mi_version_metal.reload
      mi_version.reload
      machine_image.reload
      expect(mi_version_metal.enabled).to be true
      expect(mi_version_metal.archive_size_mib).to eq(10)
    end

    it "destroys source vm when configured" do
      refresh_frame(prog, new_values: {"archive_size_bytes" => 10 * 1024 * 1024, "destroy_source_after" => true})

      expect { prog.finish }.to exit({"msg" => "Metal machine image version is created and enabled"})

      expect(source_vm.reload.destroy_set?).to be true
    end

    it "sets machine image latest version when configured" do
      refresh_frame(prog, new_values: {"archive_size_bytes" => 10 * 1024 * 1024, "set_as_latest" => true})

      expect { prog.finish }.to exit({"msg" => "Metal machine image version is created and enabled"})

      machine_image.reload
      expect(machine_image.latest_version.id).to eq(mi_version_metal.id)
    end
  end

  describe "#archive_params_json" do
    it "generates JSON payload with store credentials" do
      allow(Vm).to receive(:[]).with(source_vm.id).and_return(source_vm)

      result = JSON.parse(prog.archive_params_json)

      expect(result["kek"]).to eq(source_kek.secret_key_material_hash)
      expect(result["target_conf"]).to include(
        "endpoint" => store.endpoint,
        "region" => store.region,
        "bucket" => store.bucket,
        "prefix" => mi_version_metal.store_prefix,
        "access_key_id" => store.access_key,
        "secret_access_key" => store.secret_key,
        "archive_kek" => archive_kek.secret_key_material_hash,
      )
      expect(result).not_to have_key("vm_name")
      expect(result).not_to have_key("device")
      expect(result).not_to have_key("disk_index")
      expect(result).not_to have_key("vhost_block_backend_version")
    end
  end

  describe "#stats_file_path" do
    it "returns the expected path" do
      expect(prog.stats_file_path).to eq("/tmp/archive_stats_#{mi_version.ubid}.json")
    end
  end
end
