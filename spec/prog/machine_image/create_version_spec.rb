# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::CreateVersion do
  let(:project) { Project.create(name: "test-mi-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:vm_host) { create_vm_host }
  let(:backend) { VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 50, vm_host_id: vm_host.id) }
  let(:storage_device) { StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id) }
  let(:source_kek) { StorageKeyEncryptionKey.create_random(auth_data: "test-source-kek") }
  let(:source_vm) {
    vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
    Strand.create(prog: "Vm::Nexus", label: "stopped") { it.id = vm.id }
    vm
  }
  let(:machine_image) { MachineImage.create(name: "test-image", arch: "x64", project_id: project.id, location_id: location.id) }
  let(:storage_volume) {
    VmStorageVolume.create(
      vm_id: source_vm.id, boot: true, size_gib: 5, disk_index: 0,
      storage_device_id: storage_device.id, vhost_block_backend_id: backend.id,
      key_encryption_key_1_id: source_kek.id, vring_workers: 1
    )
  }

  before do
    allow(Config).to receive_messages(machine_image_r2_bucket: "test-bucket", machine_image_r2_account_id: "test-account")
  end

  describe ".assemble" do
    it "fails when source VM has more than one storage volume" do
      storage_volume
      VmStorageVolume.create(
        vm_id: source_vm.id, boot: false, size_gib: 10, disk_index: 1,
        storage_device_id: storage_device.id, vhost_block_backend_id: backend.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "extra").id,
        vring_workers: 1
      )

      expect {
        described_class.assemble(machine_image, "1.0", source_vm)
      }.to raise_error("source vm must have only one storage volume")
    end

    it "fails when source VM is not stopped" do
      running_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
      VmStorageVolume.create(
        vm_id: running_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: storage_device.id, vhost_block_backend_id: backend.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "x").id,
        vring_workers: 1
      )

      expect {
        described_class.assemble(machine_image, "1.0", running_vm)
      }.to raise_error("source vm must be stopped")
    end

    it "fails when source VM backend does not support archive" do
      old_backend = VhostBlockBackend.create(version: "v0.3.0", allocation_weight: 0, vm_host_id: vm_host.id)
      old_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
      Strand.create(prog: "Vm::Nexus", label: "stopped") { it.id = old_vm.id }
      VmStorageVolume.create(
        vm_id: old_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: storage_device.id, vhost_block_backend_id: old_backend.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "y").id,
        vring_workers: 1
      )

      expect {
        described_class.assemble(machine_image, "1.0", old_vm)
      }.to raise_error("source vm's vhost block backend must support archive")
    end

    it "fails when source VM has no vhost block backend" do
      no_backend_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
      Strand.create(prog: "Vm::Nexus", label: "stopped") { it.id = no_backend_vm.id }
      VmStorageVolume.create(
        vm_id: no_backend_vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: storage_device.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "z").id
      )

      expect {
        described_class.assemble(machine_image, "1.0", no_backend_vm)
      }.to raise_error("source vm's vhost block backend must support archive")
    end

    it "creates a machine image version and strand" do
      storage_volume

      strand = described_class.assemble(machine_image, "1.0", source_vm, destroy_source_after: true)

      mi_version = MachineImageVersion[strand.id]
      expect(mi_version).not_to be_nil
      expect(mi_version.machine_image_id).to eq(machine_image.id)
      expect(mi_version.version).to eq("1.0")
      expect(mi_version.enabled).to be false
      expect(mi_version.actual_size_mib).to eq(5120)
      expect(mi_version.s3_bucket).to eq("test-bucket")
      expect(mi_version.s3_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/1.0")
      expect(mi_version.s3_endpoint).to eq("https://test-account.eu.r2.cloudflarestorage.com")
      expect(mi_version.key_encryption_key).not_to be_nil

      expect(strand.prog).to eq("MachineImage::CreateVersion")
      expect(strand.label).to eq("archive")
      expect(strand.stack.first["source_vm_id"]).to eq(source_vm.id)
      expect(strand.stack.first["destroy_source_after"]).to be true
    end
  end

  describe ".r2_endpoint_url" do
    it "returns US endpoint for US locations" do
      expect(described_class.r2_endpoint_url("us-nyc1")).to eq("https://test-account.r2.cloudflarestorage.com")
    end

    it "returns EU endpoint for non-US locations" do
      expect(described_class.r2_endpoint_url("hel1")).to eq("https://test-account.eu.r2.cloudflarestorage.com")
    end
  end

  describe "instance methods" do
    subject(:prog) { described_class.new(strand) }

    let(:target_kek) { StorageKeyEncryptionKey.create_random(auth_data: "target-kek") }
    let(:mi_version) {
      MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version: "1.0",
        enabled: false,
        actual_size_mib: 5120,
        key_encryption_key_id: target_kek.id,
        s3_endpoint: "https://test-account.eu.r2.cloudflarestorage.com",
        s3_bucket: "test-bucket",
        s3_prefix: "#{project.ubid}/#{machine_image.ubid}/1.0"
      )
    }
    let(:strand) {
      Strand.create(
        prog: "MachineImage::CreateVersion",
        label: "archive",
        stack: [{
          "subject_id" => mi_version.id,
          "source_vm_id" => source_vm.id,
          "destroy_source_after" => false
        }]
      ) { it.id = mi_version.id }
    }

    before { storage_volume }

    describe "#archive" do
      let(:sshable) { source_vm.vm_host.sshable }
      let(:daemon_name) { "archive_#{mi_version.ubid}" }

      before do
        allow(prog).to receive(:archive_params_json).and_return("{}")
        allow(Vm).to receive(:[]).with(source_vm.id).and_return(source_vm)
      end

      it "cleans daemon and hops when daemon succeeded" do
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Succeeded")
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")

        expect { prog.archive }.to hop("finish")
      end

      it "starts daemon when daemon failed" do
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Failed")
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/archive-storage-volume' #{daemon_name}", stdin: "{}")

        expect { prog.archive }.to nap(30)
      end

      it "starts daemon when daemon was not started" do
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("NotStarted")
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/archive-storage-volume' #{daemon_name}", stdin: "{}")

        expect { prog.archive }.to nap(30)
      end

      it "naps when daemon is still running" do
        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("InProgress")

        expect { prog.archive }.to nap(30)
      end
    end

    describe "#finish" do
      before do
        allow(prog).to receive(:archive_size_bytes).and_return(10 * 1024 * 1024)
      end

      it "enables machine image version and updates latest version" do
        expect { prog.finish }.to exit({"msg" => "Machine image version 1.0 is created and enabled"})

        mi_version.reload
        machine_image.reload
        expect(mi_version.enabled).to be true
        expect(mi_version.archive_size_mib).to eq(10)
        expect(machine_image.latest_version_id).to eq(mi_version.id)
      end

      it "destroys source vm when configured" do
        refresh_frame(prog, new_values: {"destroy_source_after" => true})

        expect { prog.finish }.to exit({"msg" => "Machine image version 1.0 is created and enabled"})

        expect(source_vm.reload.destroy_set?).to be true
      end
    end

    describe "#archive_params_json" do
      it "generates JSON payload with temporary credentials" do
        cloudflare_client = instance_double(CloudflareClient)
        allow(CloudflareClient).to receive(:new).with("test-api-token").and_return(cloudflare_client)
        allow(cloudflare_client).to receive(:generate_temp_credentials).and_return(
          {access_key_id: "ak", secret_access_key: "sk", session_token: "st"}
        )
        allow(Config).to receive_messages(machine_image_r2_api_token: "test-api-token", machine_image_r2_access_key: "test-access-key")

        result = JSON.parse(prog.archive_params_json)

        expect(result["vm_name"]).to eq(source_vm.inhost_name)
        expect(result["device"]).to eq("vda")
        expect(result["disk_index"]).to eq(0)
        expect(result["vhost_block_backend_version"]).to eq("v0.4.0")
        expect(result["kek"]).to eq(source_kek.secret_key_material_hash)
        expect(result["target_conf"]).to include(
          "endpoint" => mi_version.s3_endpoint,
          "bucket" => mi_version.s3_bucket,
          "prefix" => mi_version.s3_prefix,
          "access_key_id" => "ak",
          "secret_access_key" => "sk",
          "session_token" => "st",
          "archive_kek" => target_kek.secret_key_material_hash
        )
      end
    end

    describe "#archive_size_bytes" do
      it "sums object sizes across pages" do
        page1 = double(contents: [double(size: 10), double(size: 20)])
        page2 = double(contents: [double(size: 5)])
        s3 = instance_double(Aws::S3::Client)

        allow(Aws::S3::Client).to receive(:new).and_return(s3)
        allow(Config).to receive_messages(machine_image_r2_access_key: "ak", machine_image_r2_secret_key: "sk")
        allow(s3).to receive(:list_objects_v2).with(
          bucket: "test-bucket",
          prefix: mi_version.s3_prefix
        ).and_return([page1, page2])

        expect(prog.archive_size_bytes).to eq(35)
      end
    end
  end
end
