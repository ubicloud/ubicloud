# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::DestroyVersionMetal do
  subject(:prog) {
    described_class.new(described_class.assemble(mi_version_metal))
  }

  let(:mi_version_metal) { create_machine_image_version_metal }
  let(:mi_version) { mi_version_metal.machine_image_version }
  let(:machine_image) { mi_version.machine_image }
  let(:project) { machine_image.project }
  let(:archive_kek) { mi_version_metal.archive_kek }
  let(:store) { mi_version_metal.store }

  describe ".assemble" do
    it "disables the version metal and creates a strand" do
      strand = described_class.assemble(mi_version_metal)

      expect(mi_version_metal.reload.enabled).to be false
      expect(strand.prog).to eq("MachineImage::DestroyVersionMetal")
      expect(strand.label).to eq("destroy_objects")
    end

    it "fails when destroying the latest version of a machine image" do
      machine_image.update(latest_version_id: mi_version.id)

      expect {
        described_class.assemble(mi_version_metal)
      }.to raise_error("Cannot destroy the latest version of a machine image")
    end

    it "fails when VMs are still using this version" do
      vm_host = create_vm_host
      vhost_block_backend = create_vhost_block_backend(allocation_weight: 50, vm_host_id: vm_host.id)
      vm = create_vm(vm_host_id: vm_host.id, project_id: project.id)
      sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
      VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 5, disk_index: 0,
        storage_device_id: sd.id, vhost_block_backend_id: vhost_block_backend.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "k1").id,
        machine_image_version_id: mi_version.id,
        vring_workers: 1,
      )

      expect {
        described_class.assemble(mi_version_metal)
      }.to raise_error("VMs are still using this machine image version")
    end
  end

  describe "#destroy_objects" do
    let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

    before do
      allow(Aws::S3::Client).to receive(:new).with(
        access_key_id: store.access_key,
        secret_access_key: store.secret_key,
        endpoint: store.endpoint,
        region: store.region,
        force_path_style: true,
        http_open_timeout: 5,
        http_read_timeout: 20,
        retry_limit: 0,
      ).and_return(s3_client)
    end

    it "hops to update_database when no objects are returned" do
      s3_client.stub_responses(:list_objects_v2, {contents: [], is_truncated: false})

      expect { prog.destroy_objects }.to hop("update_database")
    end

    it "deletes the first page of objects and naps" do
      s3_client.stub_responses(
        :list_objects_v2,
        {contents: [{key: "obj1"}, {key: "obj2"}], is_truncated: true},
        {contents: [{key: "obj3"}], is_truncated: false},
      )
      expect(s3_client).to receive(:delete_objects).with(
        bucket: store.bucket,
        delete: {objects: [{key: "obj1"}, {key: "obj2"}]},
      ).and_call_original

      expect { prog.destroy_objects }.to nap(0)
    end

    it "logs and naps if delete_objects returns per-object errors" do
      s3_client.stub_responses(
        :list_objects_v2,
        {contents: [{key: "obj1"}, {key: "obj2"}], is_truncated: false},
      )
      expect(s3_client).to receive(:delete_objects).and_return(
        Aws::S3::Types::DeleteObjectsOutput.new(
          deleted: [Aws::S3::Types::DeletedObject.new(key: "obj1")],
          errors: [Aws::S3::Types::Error.new(key: "obj2", code: "AccessDenied", message: "Access Denied")],
        ),
      )

      expect(Clog).to receive(:emit).with("Failed to delete some machine image archive objects", {
        machine_image: mi_version.machine_image.ubid,
        version: mi_version.version,
        count: 1,
        first_error: {code: "AccessDenied", key: "obj2", message: "Access Denied"},
      })

      expect { prog.destroy_objects }.to nap(30)
    end
  end

  describe "#update_database" do
    it "destroys the version metal, archive kek, and version" do
      expect { prog.update_database }.to exit({"msg" => "Metal machine image version is destroyed"})
        .and change { mi_version_metal.exists? }.from(true).to(false)
        .and change { archive_kek.exists? }.from(true).to(false)
        .and change { mi_version.exists? }.from(true).to(false)
    end
  end
end
