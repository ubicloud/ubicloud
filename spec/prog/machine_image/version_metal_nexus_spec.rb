# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::VersionMetalNexus do
  let(:source_vm) { create_archive_ready_vm }
  let(:vm_host) { source_vm.vm_host }
  let(:vbb) { vm_host.vhost_block_backends.first }
  let(:project) { source_vm.project }
  let(:metal) { create_machine_image_version_metal(project_id: project.id) }
  let(:miv) { metal.machine_image_version }
  let(:machine_image) { miv.machine_image }
  let(:store) { metal.store }
  let(:daemon) { "archive_#{miv.ubid}" }
  let(:stats_path) { "/tmp/archive_stats_#{miv.ubid}.json" }
  let(:strand) { miv.strand }
  let(:prog) { described_class.new(strand) }

  describe ".assemble_from_vm" do
    it "creates a strand at 'archive'" do
      s = described_class.assemble_from_vm(machine_image, "1.0", source_vm, store, destroy_source_after: true)
      expect(s.label).to eq("archive")
      miv_metal = s.subject.metal
      expect(miv_metal.status).to eq("creating")
      expect(miv_metal.pinned_source_vm_id).to eq(source_vm.id)
      expect(s.stack.first.values_at("source_vm_id", "destroy_source_after", "set_as_latest"))
        .to eq([source_vm.id, true, true])
    end

    it "fails when another machine image version is already being captured from the same source VM" do
      described_class.assemble_from_vm(machine_image, "1.0", source_vm, store)
      expect { described_class.assemble_from_vm(machine_image, "1.1", source_vm, store) }
        .to raise_error(MachineImageError, "Another machine image version is already being captured from this source VM")
    end

    it "fails on arch mismatch" do
      machine_image.update(arch: "arm64")
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /does not match machine image arch/)
    end

    it "fails when source VM has no host" do
      source_vm.update(vm_host_id: nil)
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /must be a metal VM/)
    end

    it "fails when source VM has more than one storage volume" do
      sd = StorageDevice.create(name: "vdb", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: source_vm.id, boot: false, size_gib: 1, disk_index: 1,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "extra").id,
        vring_workers: 1, track_written: true)
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /must have only one storage volume/)
    end

    it "fails when source VM is not stopped" do
      source_vm.strand.update(label: "wait")
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /must be stopped/)
    end

    it "fails when storage volume doesn't track writes" do
      source_vm.vm_storage_volumes.first.update(track_written: false)
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /doesn't support machine images/)
    end

    it "fails when storage volume is not encrypted" do
      source_vm.vm_storage_volumes.first.update(key_encryption_key_1_id: nil)
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /must be encrypted/)
    end

    it "fails when storage volume is too large" do
      source_vm.vm_storage_volumes.first.update(size_gib: Config.machine_image_max_size_gib + 1)
      expect { described_class.assemble_from_vm(machine_image, "1.0", source_vm, store) }
        .to raise_error(MachineImageError, /is larger than/)
    end
  end

  describe ".assemble_from_url" do
    it "picks a vbb host and creates a strand at 'archive'" do
      vbb
      s = described_class.assemble_from_url(machine_image, "2.0", "https://x/img", "abc", store, set_as_latest: false)
      expect(s.label).to eq("archive")
      miv_metal = s.subject.metal
      expect(miv_metal.status).to eq("creating")
      expect(miv_metal.pinned_source_vm_id).to be_nil
      expect(s.stack.first.values_at("url", "sha256sum", "vm_host_id", "vhost_block_backend_version", "set_as_latest"))
        .to eq(["https://x/img", "abc", vm_host.id, "v0.4.1", false])
    end

    it "fails when no vm host with archive support is found" do
      vbb.update(version_code: 300)
      expect { described_class.assemble_from_url(machine_image, "2.0", "https://x/img", "abc", store) }
        .to raise_error("no vm host with archive support found in location")
    end
  end

  describe "#archive" do
    before do
      refresh_frame(prog, new_values: {"source_vm_id" => source_vm.id, "vm_host_id" => vm_host.id})
      metal.update(pinned_source_vm_id: source_vm.id, status: "creating")
    end

    it "hops to finish_archive on Succeeded and captures stats" do
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}")
        .and_return('{"physical_size_bytes": 10485760, "logical_size_bytes": 1073741824}')
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean #{daemon}")
      expect { prog.archive }.to hop("finish_archive")
      expect(strand.stack.first["physical_size_bytes"]).to eq(10485760)
      expect(strand.stack.first["logical_size_bytes"]).to eq(1073741824)
    end

    it "cleans the daemon and naps on Failed when below MAX retries" do
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean #{daemon}")
      expect { prog.archive }.to nap(60)
      expect(strand.stack.first["archive_failures"]).to eq(1)
      expect(metal.reload.status).to eq("creating")
      expect(metal.pinned_source_vm_id).to eq(source_vm.id)
    end

    it "marks the metal failed and hops to destroy_objects after MAX retries" do
      refresh_frame(prog, new_values: {"archive_failures" => described_class::MAX_ARCHIVE_FAILURES - 1})
      expect(prog.sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("Failed")
      expect { prog.archive }.to hop("destroy_objects")
      expect(metal.reload.status).to eq("failed")
      expect(metal.pinned_source_vm_id).to be_nil
    end

    it "naps on InProgress" do
      expect(prog.sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("InProgress")
      expect { prog.archive }.to nap(30)
    end

    it "naps 60 on an unexpected daemon state" do
      expect(prog.sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("Unknown")
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: Unknown")
      expect { prog.archive }.to nap(60)
    end

    it "starts archive-storage-volume on NotStarted (VM source)" do
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("NotStarted")
      run_cmd = "common/bin/daemonizer2 run #{daemon} " \
        "sudo host/bin/archive-storage-volume #{source_vm.inhost_name} vda 0 v0.4.1 #{stats_path}"
      expect(sshable).to receive(:_cmd).with(run_cmd, stdin: a_string_including("\"kek\""), log: false)
      expect { prog.archive }.to nap(30)
    end

    it "starts archive-url on NotStarted (URL source)" do
      refresh_frame(prog, new_values: {
        "source_vm_id" => nil, "url" => "https://x/img", "sha256sum" => "abc",
        "vm_host_id" => vm_host.id, "vhost_block_backend_version" => "v0.4.1",
      })
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("NotStarted")
      run_cmd = "common/bin/daemonizer2 run #{daemon} " \
        "sudo host/bin/archive-url https://x/img abc v0.4.1 #{stats_path}"
      expect(sshable).to receive(:_cmd).with(run_cmd, stdin: satisfy { |s| !s.include?("\"kek\"") }, log: false)
      expect { prog.archive }.to nap(30)
    end
  end

  describe "#finish_archive" do
    before do
      metal.update(status: "creating", archive_size_mib: nil, pinned_source_vm_id: source_vm.id)
      miv.update(actual_size_mib: nil)
      refresh_frame(prog, new_values: {
        "source_vm_id" => source_vm.id, "destroy_source_after" => false, "set_as_latest" => true,
        "physical_size_bytes" => 10 * 1048576, "logical_size_bytes" => 100 * 1048576,
        "vm_host_id" => vm_host.id,
      })
    end

    it "marks ready, bills, sets latest, clears pinned_source_vm_id, hops wait" do
      expect(prog.sshable).to receive(:_cmd).with("sudo rm -f #{stats_path}")
      expect { prog.finish_archive }.to hop("wait")
      expect(metal.reload).to have_attributes(status: "ready", archive_size_mib: 10, pinned_source_vm_id: nil)
      expect(miv.reload.actual_size_mib).to eq(100)
      expect(BillingRecord.where(resource_id: metal.id).count).to eq(1)
      expect(machine_image.reload.latest_version_id).to eq(miv.id)
    end

    it "destroys the source VM when destroy_source_after is set" do
      refresh_frame(prog, new_values: {"destroy_source_after" => true})
      expect(prog.sshable).to receive(:_cmd).with("sudo rm -f #{stats_path}")
      expect { prog.finish_archive }.to hop("wait")
        .and change { source_vm.reload.destroy_set? }.from(false).to(true)
    end

    it "skips latest update when set_as_latest is false" do
      refresh_frame(prog, new_values: {"set_as_latest" => false})
      expect(prog.sshable).to receive(:_cmd).with("sudo rm -f #{stats_path}")
      expect { prog.finish_archive }.to hop("wait")
      expect(machine_image.reload.latest_version_id).to be_nil
    end
  end

  describe "#wait" do
    it "naps 1 year" do
      expect { prog.wait }.to nap(365 * 24 * 60 * 60)
    end
  end

  describe "#destroy" do
    before { refresh_frame(prog, new_values: {"vm_host_id" => vm_host.id}) }

    it "tears down the archive daemon when status is creating and daemon is in progress" do
      metal.update(status: "creating", pinned_source_vm_id: source_vm.id)
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("InProgress")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 stop #{daemon}")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean #{daemon}")
      expect { prog.destroy }.to hop("wait_vms")
      expect(metal.reload.status).to eq("destroying")
      expect(metal.pinned_source_vm_id).to be_nil
    end

    it "skips daemon teardown when status is creating but daemon is not in progress" do
      metal.update(status: "creating", pinned_source_vm_id: source_vm.id)
      sshable = prog.sshable
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{daemon}").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean #{daemon}")
      expect { prog.destroy }.to hop("wait_vms")
      expect(metal.reload.status).to eq("destroying")
      expect(metal.pinned_source_vm_id).to be_nil
    end

    it "decrements destroy count when destroying" do
      metal.incr_destroy
      prog = described_class.new(strand)
      expect { prog.destroy }.to hop("wait_vms")
        .and change { metal.reload.destroy_set? }.from(true).to(false)
      expect(metal.reload.status).to eq("destroying")
    end

    it "reassigns latest_version_id to the next ready version" do
      machine_image.update(latest_version_id: miv.id)
      other_miv = MachineImageVersion.create(machine_image_id: machine_image.id, version: "1.1", actual_size_mib: nil)
      other_kek = StorageKeyEncryptionKey.create_random(auth_data: "k2")
      MachineImageVersionMetal.create_with_id(other_miv, status: "ready",
        archive_kek_id: other_kek.id, store_id: store.id, store_prefix: "x", archive_size_mib: 1)
      expect { prog.destroy }.to hop("wait_vms")
      expect(machine_image.reload.latest_version_id).to eq(other_miv.id)
    end

    it "clears latest_version_id when no other ready version exists" do
      machine_image.update(latest_version_id: miv.id)
      expect { prog.destroy }.to hop("wait_vms")
      expect(machine_image.reload.latest_version_id).to be_nil
    end

    it "leaves latest_version_id alone when it points elsewhere" do
      expect { prog.destroy }.to hop("wait_vms")
      expect(machine_image.reload.latest_version_id).to be_nil
    end

    it "finalizes active billing records" do
      br = metal.create_billing_record
      br.update(span: Sequel.pg_range((Time.now - 60)..))
      expect { prog.destroy }.to hop("wait_vms")
      expect(br.reload.span.end).to be_within(60).of(Time.now)
    end
  end

  describe "#wait_vms" do
    before { metal.update(status: "destroying") }

    it "naps while a VM still references the MIV" do
      other_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "other")
      sd = StorageDevice.create(name: "sdb", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(vm_id: other_vm.id, boot: true, size_gib: 1, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k3").id,
        machine_image_version_id: miv.id, vring_workers: 1)
      expect { prog.wait_vms }.to nap(30)
    end

    it "hops to destroy_objects when no VM references the MIV" do
      expect { prog.wait_vms }.to hop("destroy_objects")
    end
  end

  describe "#destroy_objects" do
    let(:s3) { Aws::S3::Client.new(stub_responses: true) }

    before do
      metal.update(status: "destroying")
      allow(Aws::S3::Client).to receive(:new).and_return(s3)
    end

    it "hops to finish_destroy when no objects remain" do
      s3.stub_responses(:list_objects_v2, {contents: [], is_truncated: false})
      expect { prog.destroy_objects }.to hop("finish_destroy")
    end

    it "hops to failed when no objects remain and status is failed" do
      metal.update(status: "failed", archive_size_mib: nil)
      s3.stub_responses(:list_objects_v2, {contents: [], is_truncated: false})
      expect { prog.destroy_objects }.to hop("failed")
    end

    it "deletes a page and naps 0" do
      s3.stub_responses(:list_objects_v2, {contents: [{key: "a"}, {key: "b"}], is_truncated: true})
      expect(s3).to receive(:delete_objects).with(bucket: store.bucket,
        delete: {objects: [{key: "a"}, {key: "b"}]}).and_call_original
      expect { prog.destroy_objects }.to nap(0)
    end

    it "naps 30 on per-object delete errors" do
      s3.stub_responses(:list_objects_v2, {contents: [{key: "a"}], is_truncated: false})
      allow(s3).to receive(:delete_objects).and_return(
        Aws::S3::Types::DeleteObjectsOutput.new(deleted: [],
          errors: [Aws::S3::Types::Error.new(key: "a", code: "AccessDenied", message: "no")]),
      )
      expect { prog.destroy_objects }.to nap(30)
    end
  end

  describe "#finish_destroy" do
    it "destroys metal, kek, and miv then pops" do
      metal.update(status: "destroying")
      kek = metal.archive_kek
      expect { prog.finish_destroy }
        .to exit({"msg" => "Metal machine image version is destroyed"})
        .and change { metal.exists? }.from(true).to(false)
        .and change { kek.exists? }.from(true).to(false)
        .and change { miv.exists? }.from(true).to(false)
    end
  end

  describe "#failed" do
    it "naps 1 year" do
      expect { prog.failed }.to nap(365 * 24 * 60 * 60)
    end
  end

  describe "#vm_host" do
    it "returns the VM host" do
      refresh_frame(prog, new_values: {"vm_host_id" => vm_host.id})
      expect(prog.vm_host.id).to eq(vm_host.id)
    end
  end
end
