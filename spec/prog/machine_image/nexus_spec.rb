# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::Nexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-project") }
  let(:vm_host) { create_vm_host }
  let(:vm) {
    create_vm(
      vm_host_id: vm_host.id,
      display_state: "running",
      project_id: project.id
    )
  }
  let(:boot_image) { BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 20) }
  let(:storage_device) { StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", available_storage_gib: 200, total_storage_gib: 200) }
  let(:vbb) { VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 100, vm_host_id: vm_host.id) }
  let(:boot_volume) {
    VmStorageVolume.create(
      vm_id: vm.id,
      boot: true,
      size_gib: 20,
      disk_index: 0,
      storage_device_id: storage_device.id,
      vhost_block_backend_id: vbb.id,
      vring_workers: 1
    )
  }
  let(:machine_image) {
    MachineImage.create(
      name: "test-image",
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "creating",
      s3_bucket: "test-bucket",
      s3_prefix: "images/mi123/",
      s3_endpoint: "https://r2.example.com",
      encrypted: false,
      size_gib: 0,
      vm_id: vm.id
    )
  }
  let(:strand) {
    boot_volume # ensure created
    Strand.create_with_id(machine_image, prog: "MachineImage::Nexus", label: "start")
  }
  let(:sshable) { nx.host.sshable }

  before do
    allow(Config).to receive_messages(machine_image_archive_access_key: "test-key-id", machine_image_archive_secret_key: "test-secret-key")
  end

  describe "#start" do
    before do
      allow(nx.vm).to receive(:display_state).and_return("stopped")
    end

    it "hops to archive for unencrypted image" do
      expect { nx.start }.to hop("archive")
    end

    it "hops to create_kek for encrypted image" do
      machine_image.update(encrypted: true)
      nx.machine_image.reload
      expect { nx.start }.to hop("create_kek")
    end

    it "fails if VM is not stopped" do
      allow(nx.vm).to receive(:display_state).and_return("running")
      expect { nx.start }.to raise_error(RuntimeError, "VM must be stopped to create a machine image")
    end

    it "fails if VM has no boot volume" do
      boot_volume.destroy
      # Need to clear cached boot_volume
      nx.instance_variable_set(:@boot_volume, nil)
      expect { nx.start }.to raise_error(RuntimeError, "VM has no boot volume")
    end
  end

  describe "#create_kek" do
    it "creates a StorageKeyEncryptionKey and hops to archive" do
      machine_image.update(encrypted: true)
      expect { nx.create_kek }.to hop("archive")
      machine_image.reload
      expect(machine_image.key_encryption_key_1_id).not_to be_nil
      kek = machine_image.key_encryption_key_1
      expect(kek.algorithm).to eq("aes-256-gcm")
      expect(kek.auth_data).to eq(machine_image.ubid)
    end
  end

  describe "#archive" do
    it "starts the archive daemonizer when not started" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer 'sudo host\/bin\/archive-machine-image' archive_/, stdin: anything)
      expect { nx.archive }.to nap(15)
    end

    it "hops to verify_boot when succeeded" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean archive_/)
      expect { nx.archive }.to hop("verify_boot")
    end

    it "marks failed and hops to wait when archive fails" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("Failed")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/archive_.*\.stderr/).and_return("some error\n")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean archive_/)
      expect(Clog).to receive(:emit).with("Failed to create machine image archive", hash_including(machine_image_archive_failed: hash_including(stderr: "some error")))
      expect { nx.archive }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end

    it "marks failed with no stderr details when stderr read fails" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("Failed")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/archive_.*\.stderr/).and_raise(RuntimeError, "file not found")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean archive_/)
      expect(Clog).to receive(:emit).with("Failed to create machine image archive", hash_including(machine_image_archive_failed: hash_including(stderr: nil)))
      expect { nx.archive }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end

    it "naps when in progress" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("InProgress")
      expect { nx.archive }.to nap(15)
    end

    it "passes encrypted params when encrypted" do
      machine_image.update(encrypted: true)
      kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "testkey", init_vector: "iv", auth_data: machine_image.ubid)
      machine_image.update(key_encryption_key_1_id: kek.id)

      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer 'sudo host\/bin\/archive-machine-image' archive_/, stdin: anything) do |_, stdin:|
        params = JSON.parse(stdin)
        expect(params["encrypt"]).to be true
        expect(params["archive_kek"]).to eq("testkey")
      end
      expect { nx.archive }.to nap(15)
    end

    it "passes correct params to daemonizer" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer 'sudo host\/bin\/archive-machine-image' archive_/, stdin: anything) do |_, stdin:|
        params = JSON.parse(stdin)
        expect(params["device_config"]).to include("/var/storage/")
        expect(params["device_config"]).to end_with("/0/vhost-backend.conf")
        expect(params["archive_bin"]).to eq("/opt/vhost-block-backend/v0.4.0/archive")
        expect(params["s3_key_id"]).to eq("test-key-id")
        expect(params["s3_secret_key"]).to eq("test-secret-key")
        expect(params["target_config_content"]).to include("[target]")
        expect(params["target_config_content"]).to include('bucket = "test-bucket"')
        expect(params["vm_name"]).to eq(vm.inhost_name)
      end
      expect { nx.archive }.to nap(15)
    end

    it "passes disk_kek when boot volume has a key encryption key" do
      disk_kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "disk-key", init_vector: "iv", auth_data: "disk")
      boot_volume.update(key_encryption_key_1_id: disk_kek.id)
      nx.instance_variable_set(:@boot_volume, nil)

      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check archive_/).and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer 'sudo host\/bin\/archive-machine-image' archive_/, stdin: anything) do |_, stdin:|
        params = JSON.parse(stdin)
        expect(params["disk_kek"]).to eq("disk-key")
      end
      expect { nx.archive }.to nap(15)
    end
  end

  describe "#verify_boot" do
    it "creates a verification VM and hops to wait_verify_boot" do
      expect { nx.verify_boot }.to hop("wait_verify_boot")
      expect(machine_image.reload.state).to eq("verifying")
      verify_vm_id = nx.strand.stack.first["verify_vm_id"]
      expect(verify_vm_id).not_to be_nil
      expect(nx.strand.stack.first["verify_deadline"]).not_to be_nil

      # Verify the VM was actually created via assemble
      verify_vm = Vm[verify_vm_id]
      expect(verify_vm).not_to be_nil
      expect(verify_vm.name).to start_with("mi-verify-")
      expect(verify_vm.boot_image).to eq("")
      expect(verify_vm.project_id).to eq(machine_image.project_id)
    end

    it "passes machine_image_id through to storage volumes" do
      expect { nx.verify_boot }.to hop("wait_verify_boot")
      verify_vm_id = nx.strand.stack.first["verify_vm_id"]
      verify_strand = Strand[verify_vm_id]
      vol = verify_strand.stack.first["storage_volumes"].first
      expect(vol["machine_image_id"]).to eq(machine_image.id)
    end
  end

  describe "#wait_verify_boot" do
    subject(:nx) { described_class.new(strand_with_verify) }

    let(:verify_vm) { instance_double(Vm, id: "test-verify-vm-id") }
    let(:strand_with_verify) {
      boot_volume # ensure created
      st = Strand.create_with_id(machine_image, prog: "MachineImage::Nexus", label: "wait_verify_boot")
      st.stack.first.merge!(
        "verify_vm_id" => "test-verify-vm-id",
        "verify_deadline" => (Time.now + 300).to_s
      )
      st.modified!(:stack)
      st.save_changes
      st
    }

    it "destroys VM and hops to finish when VM is running" do
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(verify_vm)
      allow(verify_vm).to receive(:display_state).and_return("running")
      expect(verify_vm).to receive(:incr_destroy)

      expect { nx.wait_verify_boot }.to hop("finish")
    end

    it "hops to fail_verify_boot when VM is nil" do
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(nil)

      expect { nx.wait_verify_boot }.to hop("fail_verify_boot")
    end

    it "hops to fail_verify_boot when VM has failed" do
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(verify_vm)
      allow(verify_vm).to receive(:display_state).and_return("failed")

      expect { nx.wait_verify_boot }.to hop("fail_verify_boot")
    end

    it "hops to fail_verify_boot when deadline exceeded" do
      strand_with_verify.stack.first["verify_deadline"] = (Time.now - 60).to_s
      strand_with_verify.modified!(:stack)
      strand_with_verify.save_changes
      # Clear cached frame
      nx.instance_variable_set(:@frame, nil)

      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(verify_vm)
      allow(verify_vm).to receive(:display_state).and_return("creating")

      expect { nx.wait_verify_boot }.to hop("fail_verify_boot")
    end

    it "naps when VM is still creating" do
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(verify_vm)
      allow(verify_vm).to receive(:display_state).and_return("creating")

      expect { nx.wait_verify_boot }.to nap(15)
    end
  end

  describe "#fail_verify_boot" do
    subject(:nx) { described_class.new(strand_with_verify) }

    let(:strand_with_verify) {
      boot_volume # ensure created
      st = Strand.create_with_id(machine_image, prog: "MachineImage::Nexus", label: "fail_verify_boot")
      st.stack.first["verify_vm_id"] = "test-verify-vm-id"
      st.modified!(:stack)
      st.save_changes
      st
    }

    it "destroys VM, marks image failed, and hops to wait" do
      verify_vm = instance_double(Vm)
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(verify_vm)
      expect(verify_vm).to receive(:incr_destroy)

      expect(Clog).to receive(:emit).with("Machine image failed boot verification", anything)
      expect { nx.fail_verify_boot }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end

    it "handles nil VM gracefully" do
      allow(Vm).to receive(:[]).with("test-verify-vm-id").and_return(nil)

      expect(Clog).to receive(:emit).with("Machine image failed boot verification", anything)
      expect { nx.fail_verify_boot }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end
  end

  describe "#finish" do
    it "sets state to available and hops to wait" do
      expect { nx.finish }.to hop("wait")
      expect(machine_image.reload.state).to eq("available")
      expect(machine_image.size_gib).to eq(20)
    end

    it "creates a billing record when project is billable" do
      project.update(billable: true)
      expect { nx.finish }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
      br = machine_image.active_billing_records.first
      expect(br.billing_rate["resource_type"]).to eq("MachineImageStorage")
      expect(br.amount).to eq(20)
      expect(br.resource_name).to eq("test-image")
    end

    it "does not create a billing record when project is not billable" do
      project.update(billable: false)
      expect { nx.finish }.to hop("wait")
      expect(BillingRecord.count).to eq(0)
    end

    it "does not create a duplicate billing record if one already exists" do
      project.update(billable: true)
      BillingRecord.create(
        project_id: project.id,
        resource_id: machine_image.id,
        resource_name: machine_image.name,
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", "hetzner-fsn1")["id"],
        amount: 20
      )
      expect { nx.finish }.to hop("wait")
      expect(BillingRecord.count).to eq(1)
    end

    it "logs warning when billing rate is not found for location" do
      project.update(billable: true)
      expect(BillingRate).to receive(:from_resource_properties)
        .with("MachineImageStorage", "standard", "hetzner-fsn1")
        .and_return(nil)
      expect(Clog).to receive(:emit).with("No billing rate found for machine image", anything)
      expect { nx.finish }.to hop("wait")
      expect(BillingRecord.count).to eq(0)
    end
  end

  describe "#wait" do
    it "hops to destroy when destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "naps when no semaphore is set" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to destroy when image is failed and older than 1 hour" do
      machine_image.update(state: "failed", created_at: Time.now - 3601)
      expect { nx.wait }.to hop("destroy")
    end

    it "naps when image is failed but within grace period" do
      machine_image.update(state: "failed", created_at: Time.now - 1800)
      expect { nx.wait }.to nap(30)
    end

    it "naps when image is available (not failed)" do
      machine_image.update(state: "available")
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "finalizes active billing records and hops to destroy_record" do
      project.update(billable: true)
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: machine_image.id,
        resource_name: machine_image.name,
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", "hetzner-fsn1")["id"],
        amount: 20
      )

      expect { nx.destroy }.to hop("destroy_record")
      expect(machine_image.reload.state).to eq("destroying")
      expect(BillingRecord[br.id].span.unbounded_end?).to be false
    end

    it "sets state to destroying and hops to destroy_record" do
      expect { nx.destroy }.to hop("destroy_record")
      expect(machine_image.reload.state).to eq("destroying")
    end
  end

  describe "#destroy_record" do
    it "deletes S3 objects, destroys KEK, and destroys the record" do
      machine_image.update(encrypted: true)
      kek = StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "testkey", init_vector: "iv", auth_data: "test")
      machine_image.update(key_encryption_key_1_id: kek.id)

      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output,
        contents: [instance_double(Aws::S3::Types::Object, key: "images/mi123/metadata.json")],
        is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)
      expect(s3_client).to receive(:delete_objects).with(
        bucket: "test-bucket",
        delete: {objects: [{key: "images/mi123/metadata.json"}]}
      )

      mi_id = machine_image.id
      kek_id = kek.id
      expect { nx.destroy_record }.to exit({"msg" => "machine image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
      expect(StorageKeyEncryptionKey[kek_id]).to be_nil
    end

    it "handles encrypted image with nil KEK reference" do
      machine_image.update(encrypted: true)

      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output,
        contents: [],
        is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)

      mi_id = machine_image.id
      expect { nx.destroy_record }.to exit({"msg" => "machine image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
    end

    it "nulls out machine_image_id on referencing volumes before destroying" do
      # Create a VM with a storage volume that references this machine image
      other_vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "other-vm")
      vol = VmStorageVolume.create(
        vm_id: other_vm.id,
        boot: true,
        size_gib: 20,
        disk_index: 0,
        machine_image_id: machine_image.id,
        storage_device_id: storage_device.id,
        vhost_block_backend_id: vbb.id,
        vring_workers: 1
      )

      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output, contents: [], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)

      mi_id = machine_image.id
      expect { nx.destroy_record }.to exit({"msg" => "machine image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
      expect(vol.reload.machine_image_id).to be_nil
    end

    it "handles unencrypted images (no KEK)" do
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output,
        contents: [],
        is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)

      mi_id = machine_image.id
      expect { nx.destroy_record }.to exit({"msg" => "machine image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
    end

    it "handles paginated S3 object listing" do
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)

      page1 = instance_double(Aws::S3::Types::ListObjectsV2Output,
        contents: [instance_double(Aws::S3::Types::Object, key: "images/mi123/metadata.json")],
        is_truncated: true,
        next_continuation_token: "token1")
      page2 = instance_double(Aws::S3::Types::ListObjectsV2Output,
        contents: [instance_double(Aws::S3::Types::Object, key: "images/mi123/stripe-mapping")],
        is_truncated: false)

      expect(s3_client).to receive(:list_objects_v2).with(bucket: "test-bucket", prefix: "images/mi123/").and_return(page1)
      expect(s3_client).to receive(:list_objects_v2).with(bucket: "test-bucket", prefix: "images/mi123/", continuation_token: "token1").and_return(page2)
      expect(s3_client).to receive(:delete_objects).with(
        bucket: "test-bucket",
        delete: {objects: [{key: "images/mi123/metadata.json"}, {key: "images/mi123/stripe-mapping"}]}
      )

      mi_id = machine_image.id
      expect { nx.destroy_record }.to exit({"msg" => "machine image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
    end
  end

  describe "#target_config_toml" do
    it "generates correct TOML for unencrypted image" do
      toml = nx.send(:target_config_toml)
      expect(toml).to include("[target]")
      expect(toml).to include('storage = "s3"')
      expect(toml).to include('bucket = "test-bucket"')
      expect(toml).to include('prefix = "images/mi123/"')
      expect(toml).to include('endpoint = "https://r2.example.com"')
      expect(toml).to include("connections = 16")
      expect(toml).to include("[secrets.s3-key-id]")
      expect(toml).to include("[secrets.s3-secret-key]")
      expect(toml).not_to include("archive_kek")
    end

    it "generates correct TOML for encrypted image" do
      machine_image.update(encrypted: true)
      toml = nx.send(:target_config_toml)
      expect(toml).to include('archive_kek.ref = "archive-kek"')
      expect(toml).to include("[secrets.archive-kek]")
      expect(toml).to include("archive-kek.pipe")
    end
  end

  describe "#device_config_path" do
    it "returns correct path for DEFAULT storage device" do
      path = nx.send(:device_config_path)
      expect(path).to eq("/var/storage/#{vm.inhost_name}/0/vhost-backend.conf")
    end

    it "returns correct path when storage device is nil" do
      boot_volume.update(storage_device_id: nil)
      nx.instance_variable_set(:@boot_volume, nil)
      path = nx.send(:device_config_path)
      expect(path).to eq("/var/storage/#{vm.inhost_name}/0/vhost-backend.conf")
    end

    it "returns correct path for named storage device" do
      storage_device.update(name: "nvme0")
      # Clear cached boot_volume
      nx.instance_variable_set(:@boot_volume, nil)
      path = nx.send(:device_config_path)
      expect(path).to eq("/var/storage/devices/nvme0/#{vm.inhost_name}/0/vhost-backend.conf")
    end
  end

  describe "#archive_bin" do
    it "returns archive binary path based on vhost block backend version" do
      expect(nx.send(:archive_bin)).to eq("/opt/vhost-block-backend/v0.4.0/archive")
    end

    it "defaults to v0.4.0 when no vhost block backend" do
      boot_volume.update(vhost_block_backend_id: nil, vring_workers: nil)
      nx.instance_variable_set(:@boot_volume, nil)
      expect(nx.send(:archive_bin)).to eq("/opt/vhost-block-backend/v0.4.0/archive")
    end
  end
end
