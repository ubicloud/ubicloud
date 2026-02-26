# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::Nexus do
  subject(:nx) {
    described_class.new(Strand.new(prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => version.id}])).tap {
      it.instance_variable_set(:@machine_image_version, version)
      it.instance_variable_set(:@vm, vm)
      it.instance_variable_set(:@host, vm_host)
    }
  }

  let(:project) {
    prj = Project.create(name: "test-project")
    prj.update(billable: true)
    prj
  }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:vm_host) { create_vm_host }
  let(:sshable) { vm_host.sshable }

  let(:mi) {
    MachineImage.create(
      name: "test-image",
      description: "test desc",
      project_id: project.id,
      location_id: location.id,
      visible: false
    )
  }

  let(:vm) {
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "test-vm", location_id: location.id).subject
    vm.update(vm_host_id: vm_host.id)
    vm.strand.update(label: "stopped")
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0)
    vm
  }

  let(:version) {
    MachineImageVersion.create(
      machine_image_id: mi.id,
      version: 1,
      state: "creating",
      vm_id: vm.id,
      size_gib: 20,
      arch: "arm64",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
  }

  let(:daemon_name) { "archive_#{version.ubid}" }

  describe ".assemble" do
    it "creates a strand" do
      st = described_class.assemble(version)
      expect(st).to be_a(Strand)
      expect(st.prog).to eq("MachineImage::Nexus")
      expect(st.label).to eq("start")
      expect(st.id).to eq(version.id)
    end
  end

  describe "#start" do
    it "registers deadline and hops to create_kek" do
      expect(nx).to receive(:register_deadline).with(nil, 86400)
      expect { nx.start }.to hop("create_kek")
    end

    it "fails if VM is not stopped" do
      vm.strand.update(label: "wait")
      expect { nx.start }.to raise_error(RuntimeError, "VM must be stopped to create a machine image")
    end

    it "fails if VM has no boot volume" do
      VmStorageVolume.where(vm_id: vm.id).each(&:destroy)
      nx.instance_variable_set(:@boot_volume, nil)
      expect { nx.start }.to raise_error(RuntimeError, "VM has no boot volume")
    end
  end

  describe "#create_kek" do
    it "creates a StorageKeyEncryptionKey and hops to archive" do
      expect { nx.create_kek }.to hop("archive")
      version.reload
      expect(version.key_encryption_key_1).not_to be_nil
      expect(version.key_encryption_key_1.algorithm).to eq("aes-256-gcm")
      expect(version.key_encryption_key_1.auth_data).to eq(version.ubid)
    end
  end

  describe "#archive" do
    before do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("test-key-32-bytes-long-enough!!!"),
        init_vector: Base64.encode64("test-iv-16bytes!"),
        auth_data: version.ubid
      )
      version.update(key_encryption_key_1_id: kek.id)
    end

    it "hops to finish on Succeeded" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.archive }.to hop("finish")
    end

    it "includes disk_kek when boot volume has encryption key" do
      boot_vol_kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("boot-vol-key-32-bytes-long!!!!!"),
        init_vector: Base64.encode64("boot-iv-16bytes!"),
        auth_data: "boot-vol"
      )
      boot_vol = vm.vm_storage_volumes.find(&:boot)
      boot_vol.update(key_encryption_key_1_id: boot_vol_kek.id)
      nx.instance_variable_set(:@boot_volume, nil) # reset cached value

      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("NotStarted")
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/archive-machine-image' #{daemon_name}", stdin: anything) do |_, opts|
        params = JSON.parse(opts[:stdin])
        expect(params).to have_key("disk_kek")
      end
      expect { nx.archive }.to nap(15)
    end

    it "starts the daemon on NotStarted" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("NotStarted")
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/archive-machine-image' #{daemon_name}", stdin: anything)
      expect { nx.archive }.to nap(15)
    end

    it "handles failure by setting state to failed and hopping to wait" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stderr").and_return("some error")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.archive }.to hop("wait")
      expect(version.reload.state).to eq("failed")
    end

    it "handles failure when stderr read fails" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stderr").and_raise(RuntimeError)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.archive }.to hop("wait")
      expect(version.reload.state).to eq("failed")
    end

    it "naps when status is in progress" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("InProgress")
      expect { nx.archive }.to nap(15)
    end
  end

  describe "#finish" do
    it "sets version to available with size and activated_at" do
      expect { nx.finish }.to hop("wait")
      version.reload
      expect(version.state).to eq("available")
      expect(version.size_gib).to eq(20)
      expect(version.activated_at).not_to be_nil
    end

    it "creates billing record when project is billable and rate exists" do
      nx # eagerly evaluate before mocking
      billing_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")
      expect(BillingRate).to receive(:from_resource_properties).with("MachineImageStorage", "standard", location.name).and_return(billing_rate)
      expect { nx.finish }.to hop("wait").and change(BillingRecord, :count).by(1)
      br = BillingRecord.where(resource_id: version.id).first
      expect(br.project_id).to eq(project.id)
      expect(br.resource_name).to eq("test-image")
      expect(br.amount).to eq(20)
    end

    it "skips billing when project is not billable" do
      project.update(billable: false)
      expect { nx.finish }.to hop("wait")
      expect(BillingRecord.where(resource_id: version.id).count).to eq(0)
    end

    it "logs when no billing rate found" do
      nx # eagerly evaluate to trigger VM assembly before mocking
      project.update(billable: true)
      expect(BillingRate).to receive(:from_resource_properties).and_return(nil)
      expect(Clog).to receive(:emit)
      expect { nx.finish }.to hop("wait")
    end

    it "skips billing when billing records already exist" do
      billing_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")
      BillingRecord.create(
        project_id: project.id,
        resource_id: version.id,
        resource_name: "test-image",
        billing_rate_id: billing_rate["id"],
        amount: 20
      )
      initial_count = BillingRecord.count
      expect { nx.finish }.to hop("wait")
      expect(BillingRecord.count).to eq(initial_count)
    end
  end

  describe "#wait" do
    it "hops to destroy when destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "auto-destroys failed versions older than 1 hour" do
      version.update(state: "failed", created_at: Time.now - 7200)
      expect(nx).to receive(:when_destroy_set?)
      expect { nx.wait }.to hop("destroy")
    end

    it "naps for 30 seconds when nothing to do" do
      expect(nx).to receive(:when_destroy_set?)
      expect { nx.wait }.to nap(30)
    end

    it "does not auto-destroy failed versions less than 1 hour old" do
      version.update(state: "failed", created_at: Time.now - 1800)
      expect(nx).to receive(:when_destroy_set?)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "finalizes billing, sets state to destroying, and hops to destroy_record" do
      expect(nx).to receive(:decr_destroy)
      expect { nx.destroy }.to hop("destroy_record")
      expect(version.reload.state).to eq("destroying")
    end

    it "finalizes active billing records" do
      billing_rate = BillingRate.from_resource_properties("VmVCpu", "standard", "hetzner-fsn1")
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: version.id,
        resource_name: "test-image",
        billing_rate_id: billing_rate["id"],
        amount: 1
      )
      expect(nx).to receive(:decr_destroy)
      expect(version).to receive(:active_billing_records).and_return([br])
      expect(br).to receive(:finalize)
      expect { nx.destroy }.to hop("destroy_record")
    end
  end

  describe "#destroy_record" do
    before do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("test-key-32-bytes-long-enough!!!"),
        init_vector: Base64.encode64("test-iv-16bytes!"),
        auth_data: version.ubid
      )
      version.update(key_encryption_key_1_id: kek.id)
    end

    it "registers deadline with allow_extension and completes when no more objects" do
      expect(nx).to receive(:register_deadline).with(nil, 600, allow_extension: true)
      expect(nx).to receive(:delete_s3_objects_batch).and_return(false)
      kek_id = version.key_encryption_key_1_id
      expect { nx.destroy_record }.to exit({"msg" => "machine image version destroyed"})
      expect(MachineImageVersion[version.id]).to be_nil
      expect(StorageKeyEncryptionKey[kek_id]).to be_nil
    end

    it "naps when more objects remain" do
      expect(nx).to receive(:register_deadline).with(nil, 600, allow_extension: true)
      expect(nx).to receive(:delete_s3_objects_batch).and_return(true)
      expect { nx.destroy_record }.to nap(0)
    end

    it "handles version without KEK" do
      version.update(key_encryption_key_1_id: nil)
      expect(nx).to receive(:register_deadline).with(nil, 600, allow_extension: true)
      expect(nx).to receive(:delete_s3_objects_batch).and_return(false)
      expect { nx.destroy_record }.to exit({"msg" => "machine image version destroyed"})
      expect(MachineImageVersion[version.id]).to be_nil
    end
  end

  describe "#delete_s3_objects_batch" do
    it "deletes objects and returns false when fewer than batch size" do
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      obj = double(key: "images/test/chunk001")
      response = double(contents: [obj], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)
      expect(s3_client).to receive(:delete_objects).with(bucket: "test-bucket", delete: {objects: [{key: "images/test/chunk001"}]})
      expect(nx.send(:delete_s3_objects_batch)).to be false
    end

    it "returns false when no objects exist" do
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = double(contents: [], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)
      expect(nx.send(:delete_s3_objects_batch)).to be false
    end

    it "stops listing at batch size and returns true" do
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      objs = (1..5000).map { |i| double(key: "images/test/chunk#{i}") }
      response = double(contents: objs, is_truncated: true, next_continuation_token: "token1")
      expect(s3_client).to receive(:list_objects_v2).and_return(response)
      expect(s3_client).to receive(:delete_objects).exactly(5).times
      expect(nx.send(:delete_s3_objects_batch)).to be true
    end

    it "paginates listing within a batch" do
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      obj1 = double(key: "images/test/chunk001")
      obj2 = double(key: "images/test/chunk002")
      response1 = double(contents: [obj1], is_truncated: true, next_continuation_token: "token1")
      response2 = double(contents: [obj2], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).with(hash_including(bucket: "test-bucket")).and_return(response1)
      expect(s3_client).to receive(:list_objects_v2).with(hash_including(continuation_token: "token1")).and_return(response2)
      expect(s3_client).to receive(:delete_objects)
      expect(nx.send(:delete_s3_objects_batch)).to be false
    end
  end
end
