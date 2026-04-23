# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::VersionMetalNexus do
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
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "src-kek").id,
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
      access_key: "ak",
      secret_key: "sk",
    )
  }

  let(:url) { "https://example.com/image.raw" }
  let(:sha256sum) { "abc123" }

  describe ".assemble_from_vm" do
    it "fails when source VM is not a metal VM" do
      vm_without_host = create_vm(project_id: project.id, name: "vm-without-host")
      expect {
        described_class.assemble_from_vm(machine_image, "1.0", vm_without_host, store)
      }.to raise_error("source vm must be a metal vm")
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
      }.to raise_error("source vm must have only one storage volume")
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
      }.to raise_error("source vm must be stopped")
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
        described_class.assemble_from_vm(machine_image, "1.0", old_vm, store)
      }.to raise_error("source vm's vhost block backend must support archive")
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
        described_class.assemble_from_vm(machine_image, "1.0", no_backend_vm, store)
      }.to raise_error("source vm's vhost block backend must support archive")
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
        described_class.assemble_from_vm(machine_image, "1.0", unencrypted_vm, store)
      }.to raise_error("source vm's storage volume must be encrypted")
    end

    it "creates the metal row, archive kek, and a strand starting at 'start'" do
      strand = described_class.assemble_from_vm(machine_image, "2.0", source_vm, store, destroy_source_after: true)

      metal = MachineImageVersionMetal[strand.id]
      expect(metal).not_to be_nil
      expect(metal.enabled).to be false
      expect(metal.store_id).to eq(store.id)
      expect(metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(metal.archive_kek).not_to be_nil
      expect(metal.machine_image_version.actual_size_mib).to be_nil

      expect(strand.prog).to eq("MachineImage::VersionMetalNexus")
      expect(strand.label).to eq("start")
      expect(strand.stack.first).to include(
        "source" => "vm",
        "source_vm_id" => source_vm.id,
        "destroy_source_after" => true,
        "set_as_latest" => true,
      )
    end
  end

  describe ".assemble_from_url" do
    it "fails when no vm host with archive support exists in location" do
      expect {
        described_class.assemble_from_url(machine_image, "v0.1", url, sha256sum, store)
      }.to raise_error("no vm host with archive support found in location")
    end

    it "creates the metal row and a strand with url frame" do
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id)
      strand = described_class.assemble_from_url(machine_image, "2.0", url, sha256sum, store)

      metal = MachineImageVersionMetal[strand.id]
      expect(metal).not_to be_nil
      expect(metal.enabled).to be false
      expect(metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(metal.machine_image_version.actual_size_mib).to be_nil

      expect(strand.prog).to eq("MachineImage::VersionMetalNexus")
      expect(strand.label).to eq("start")
      expect(strand.stack.first).to include(
        "source" => "url",
        "url" => url,
        "sha256sum" => sha256sum,
        "vm_host_id" => vm_host.id,
        "vhost_block_backend_version" => vbb.version,
        "set_as_latest" => true,
      )
    end

    it "selects only from backends that support archive" do
      create_vhost_block_backend(version: "v0.3.0", allocation_weight: 5000, vm_host_id: vm_host.id)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id)
      strand = described_class.assemble_from_url(machine_image, "2.0", url, sha256sum, store)
      expect(strand.stack.first["vhost_block_backend_version"]).to eq(vbb.version)
    end
  end

  describe "#start" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }

    it "hops to archive" do
      expect { prog.start }.to hop("archive")
    end
  end

  describe "#archive (vm source)" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }
    let(:miv) { metal.machine_image_version }
    let(:sshable) { source_vm.vm_host.sshable }
    let(:daemon_name) { "archive_#{miv.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{miv.ubid}.json" }

    before { allow(Vm).to receive(:[]).with(source_vm.id).and_return(source_vm) }

    it "runs the storage-volume archive command when not started" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-storage-volume", source_vm.inhost_name, "vda", 0, vhost_block_backend.version, stats_path,
        stdin: prog.archive_params_json, log: false)
      expect { prog.archive }.to nap(30)
    end

    it "reads stats and hops to finish on success" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}").and_return('{"physical_size_bytes": 10485760, "logical_size_bytes": 1073741824}')
      expect(sshable).to receive(:d_clean).with(daemon_name)
      expect { prog.archive }.to hop("finish_create")
      expect(strand.stack.first["physical_size_bytes"]).to eq(10485760)
      expect(strand.stack.first["logical_size_bytes"]).to eq(1073741824)
    end

    it "restarts on failure" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive }.to nap(60)
    end

    it "naps when in progress" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("InProgress")
      expect { prog.archive }.to nap(30)
    end

    it "logs unexpected status" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Mystery")
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: Mystery")
      expect { prog.archive }.to nap(60)
    end

    it "archive_params_json includes kek for vm source" do
      result = JSON.parse(prog.archive_params_json)
      expect(result["kek"]).to eq(source_kek.secret_key_material_hash)
      expect(result["target_conf"]).to include(
        "endpoint" => store.endpoint,
        "bucket" => store.bucket,
        "prefix" => metal.store_prefix,
      )
    end
  end

  describe "#archive (url source)" do
    let(:vbb) { create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id) }
    let(:strand) {
      vbb
      described_class.assemble_from_url(machine_image, "1.0", url, sha256sum, store)
    }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }
    let(:miv) { metal.machine_image_version }
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_#{miv.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{miv.ubid}.json" }

    before { allow(VmHost).to receive(:[]).with(vm_host.id).and_return(vm_host) }

    it "runs the url archive command when not started" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-url", url, sha256sum, "v0.4.1", stats_path,
        stdin: prog.archive_params_json, log: false)
      expect { prog.archive }.to nap(30)
    end

    it "archive_params_json omits kek for url source" do
      result = JSON.parse(prog.archive_params_json)
      expect(result).not_to have_key("kek")
      expect(result["target_conf"]).to include("bucket" => store.bucket)
    end
  end

  describe "#finish_create" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }
    let(:miv) { metal.machine_image_version }

    before do
      allow(Vm).to receive(:[]).with(source_vm.id).and_return(source_vm)
      allow(source_vm.vm_host.sshable).to receive(:_cmd).with("sudo rm -f /tmp/archive_stats_#{miv.ubid}.json")
    end

    it "enables metal, sets archive and actual size, and hops to wait" do
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024})
      expect { prog.finish_create }.to hop("wait")
      expect(metal.reload.enabled).to be true
      expect(metal.archive_size_mib).to eq(10)
      expect(miv.reload.actual_size_mib).to eq(20)
      expect(machine_image.reload.latest_version_id).to eq(miv.id)
    end

    it "destroys source vm when destroy_source_after is set" do
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024, "destroy_source_after" => true})
      expect { prog.finish_create }.to hop("wait")
      expect(source_vm.reload.destroy_set?).to be true
    end

    it "does not set latest_version when set_as_latest is false" do
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024, "set_as_latest" => false})
      expect { prog.finish_create }.to hop("wait")
      expect(machine_image.reload.latest_version_id).to be_nil
    end

    it "skips finalization when destroy semaphore is set" do
      Semaphore.incr(metal.id, :destroy)
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024, "destroy_source_after" => true})
      expect { prog.finish_create }.to hop("wait")
      expect(metal.reload.enabled).to be false
      expect(metal.archive_size_mib).to be_nil
      expect(miv.reload.actual_size_mib).to be_nil
      expect(machine_image.reload.latest_version_id).to be_nil
      expect(source_vm.reload.destroy_set?).to be false
    end

    it "detects a destroy committed after the prog's SemSnap was populated" do
      # The prog (and its SemSnap) are constructed above without a destroy
      # semaphore. Simulate a concurrent request_destroy committing between
      # SemSnap's read and our FOR SHARE acquire by inserting the semaphore
      # now and confirming finish_create still skips finalization.
      prog  # force prog (and its SemSnap) to be built first
      Semaphore.incr(metal.id, :destroy)
      expect(prog.destroy_set?).to be false  # stale snap
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024})
      expect { prog.finish_create }.to hop("wait")
      expect(metal.reload.enabled).to be false
      expect(machine_image.reload.latest_version_id).to be_nil
    end

    it "works for url source (no destroy_source_after handling)" do
      vhost_block_backend  # ensure backend exists for assemble_from_url's selection
      url_only_image = MachineImage.create(name: "url-mi", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      url_strand = described_class.assemble_from_url(url_only_image, "2.0", url, sha256sum, store)
      url_prog = described_class.new(url_strand)
      url_metal = MachineImageVersionMetal[url_strand.id]
      url_miv = url_metal.machine_image_version
      allow(VmHost).to receive(:[]).with(vm_host.id).and_return(vm_host)
      allow(vm_host.sshable).to receive(:_cmd).with("sudo rm -f /tmp/archive_stats_#{url_miv.ubid}.json")
      refresh_frame(url_prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024})
      expect { url_prog.finish_create }.to hop("wait")
      expect(url_miv.reload.actual_size_mib).to eq(20)
    end
  end

  describe "#wait" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }

    it "naps for 6 hours" do
      expect { prog.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "destroy semaphore" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }

    it "wait hops to destroy when destroy semaphore is set" do
      Semaphore.incr(metal.id, :destroy)
      expect { prog.wait }.to hop("destroy")
    end

    it "before_run does not hop to destroy during creation" do
      Semaphore.incr(metal.id, :destroy)
      expect { prog.before_run }.not_to hop
    end
  end

  describe "#destroy" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }

    it "disables metal and hops to destroy_objects" do
      metal.update(enabled: true, archive_size_mib: 100)
      expect { prog.destroy }.to hop("destroy_objects")
      expect(metal.reload.enabled).to be false
    end
  end

  describe "#destroy_objects" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

    before do
      allow(Aws::S3::Client).to receive(:new).with(
        access_key_id: store.access_key, secret_access_key: store.secret_key,
        endpoint: store.endpoint, region: store.region,
        force_path_style: true, http_open_timeout: 5, http_read_timeout: 20, retry_limit: 0,
      ).and_return(s3_client)
    end

    it "hops to finish_destroy when bucket is empty" do
      s3_client.stub_responses(:list_objects_v2, {contents: [], is_truncated: false})
      expect { prog.destroy_objects }.to hop("finish_destroy")
    end

    it "deletes a page and naps" do
      s3_client.stub_responses(:list_objects_v2, {contents: [{key: "obj1"}, {key: "obj2"}], is_truncated: true})
      expect(s3_client).to receive(:delete_objects).with(
        bucket: store.bucket, delete: {objects: [{key: "obj1"}, {key: "obj2"}]},
      ).and_call_original
      expect { prog.destroy_objects }.to nap(0)
    end

    it "logs and naps if delete_objects returns errors" do
      s3_client.stub_responses(:list_objects_v2, {contents: [{key: "obj1"}], is_truncated: false})
      expect(s3_client).to receive(:delete_objects).and_return(
        Aws::S3::Types::DeleteObjectsOutput.new(
          deleted: [],
          errors: [Aws::S3::Types::Error.new(key: "obj1", code: "AccessDenied", message: "Access Denied")],
        ),
      )
      expect(Clog).to receive(:emit).with("Failed to delete some machine image archive objects", hash_including(count: 1))
      expect { prog.destroy_objects }.to nap(30)
    end
  end

  describe "#finish_destroy" do
    let(:strand) { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
    let(:prog) { described_class.new(strand) }
    let(:metal) { MachineImageVersionMetal[strand.id] }

    it "destroys metal, archive_kek, and miv; leaves machine image" do
      archive_kek = metal.archive_kek
      miv = metal.machine_image_version
      expect { prog.finish_destroy }.to exit({"msg" => "Metal machine image version is destroyed"})
        .and change { metal.exists? }.from(true).to(false)
        .and change { archive_kek.exists? }.from(true).to(false)
        .and change { miv.exists? }.from(true).to(false)
      expect(machine_image.exists?).to be true
    end
  end
end
