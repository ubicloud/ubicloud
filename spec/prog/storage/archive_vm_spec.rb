# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::ArchiveVm do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:vm_host) {
    vm_host = create_vm_host
    vbb = VhostBlockBackend.create(version: Config.vhost_block_backend_version, allocation_weight: 0, vm_host_id: vm_host.id)
    vm_host.add_vhost_block_backend(vbb)
    vm_host
  }
  let(:kek) {
    StorageKeyEncryptionKey.create(
      algorithm: "aes-256-gcm",
      key: "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=",
      init_vector: "YmJiYmJiYmJiYmJi",
      auth_data: "testdata"
    )
  }
  let(:storage_device) {
    StorageDevice.create(
      name: "DEFAULT",
      total_storage_gib: 100,
      available_storage_gib: 80
    )
  }
  let(:vm) {
    vm = create_vm(vm_host_id: vm_host.id)
    volume = VmStorageVolume.create(
      boot: true,
      size_gib: 20,
      disk_index: 0,
      storage_device:,
      key_encryption_key_1_id: kek.id,
      vm_id: vm.id,
      vhost_block_backend_id: vm_host.vhost_block_backends.first.id,
      vring_workers: 1
    )
    vm.add_vm_storage_volume(volume)
    vm
  }
  let(:machine_image) {
    MachineImage.create(
      name: "test-image",
      bucket_prefix: "test-prefix",
      project_id: vm.project_id,
      location_id: vm.location_id
    )
  }

  before do
    allow(Config).to receive_messages(
      storage_archive_access_key: "test_access_key",
      storage_archive_secret_key: "test_secret_key",
      storage_archive_bucket: "test_bucket",
      storage_archive_endpoint: "r2.com"
    )
    allow(prog).to receive(:vm).and_return(vm)
  end

  describe "#assemble" do
    it "fails if storage archive credentials are not configured" do
      allow(Config).to receive(:storage_archive_access_key).and_return(nil)
      expect {
        described_class.assemble(vm.id, machine_image.id)
      }.to raise_error("Storage archive credentials are not configured")
    end

    it "fails because vm does not exist" do
      expect {
        described_class.assemble("a66aa247-1c7c-4a21-bd9b-e8abfcec6354", machine_image.id)
      }.to raise_error("Vm does not exist")
    end

    context "when vm exists" do
      before do
        expect(Vm).to receive(:[]).with(vm.id).and_return(vm)
      end

      it "fails because vm's disk is not 20GB" do
        vm.vm_storage_volumes.first.update(size_gib: 10)
        vm.reload
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("Only vms with 20GB disk can be archived")
      end

      it "fails because vm does not have exactly one VmStorageVolume" do
        vm.vm_storage_volumes.each(&:destroy)
        vm.reload
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("This prog only supports Vms with exactly one disk")
      end

      it "fails if the vm is not using ubiblk" do
        vm.vm_storage_volumes.first.update(vhost_block_backend_id: nil, vring_workers: nil)
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("Vm is not using Ubiblk")
      end

      it "fails if the vm is not encrypted" do
        vm.vm_storage_volumes.first.update(key_encryption_key_1_id: nil)
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("Vm is not encrypted")
      end

      it "fails if the underlying vmhost does not have a vhost block backend" do
        vm.vm_storage_volumes.first.update(vhost_block_backend_id: nil, vring_workers: nil)
        vm_host.vhost_block_backends.each(&:destroy)

        volume = vm.vm_storage_volumes.first
        allow(volume).to receive_messages(
          vhost_block_backend_id: SecureRandom.uuid,
          key_encryption_key_1: kek
        )
        allow(vm).to receive(:vm_storage_volumes).and_return([volume])

        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("VmHost does not have any vhost block backend installed")
      end

      it "fails if the archive binary does not exist" do
        expect(vm.vm_host.sshable).to receive(:_cmd).with("test -f /opt/vhost-block-backend/#{Config.vhost_block_backend_version}/archive").and_raise(Sshable::SshError.new("cmd", "", "", 1, nil))
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.to raise_error("Archive binary not found at /opt/vhost-block-backend/#{Config.vhost_block_backend_version}/archive")
      end

      it "creates the strand" do
        expect(vm.vm_host.sshable).to receive(:_cmd).with("test -f /opt/vhost-block-backend/#{Config.vhost_block_backend_version}/archive").and_return("")
        expect {
          described_class.assemble(vm.id, machine_image.id)
        }.not_to raise_error
      end
    end
  end

  describe "#stop_vm" do
    it "stops the vm and hops to wait_vm_stop" do
      expect(prog).to receive(:register_deadline).with(nil, 60 * 60)
      expect(vm).to receive(:incr_stop)
      expect { prog.stop_vm }.to hop("wait_vm_stop")
    end
  end

  describe "#wait_vm_stop" do
    it "naps if vm has not stopped yet" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm.inhost_name}").and_return("active")
      expect { prog.wait_vm_stop }.to nap(5)
    end

    it "hops to create_archive_conf if vm is inactive via command success" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm.inhost_name}").and_return("inactive")
      expect { prog.wait_vm_stop }.to hop("create_archive_conf")
    end

    it "hops to create_archive_conf if vm is inactive via command exception" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm.inhost_name}").and_raise(Sshable::SshError.new("cmd", "inactive\n", "stderr", 3, nil))
      expect { prog.wait_vm_stop }.to hop("create_archive_conf")
    end
  end

  describe "#create_archive_conf" do
    it "writes archive config and hops to create_kek_pipe" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with(
        "sudo tee /var/storage/#{vm.inhost_name}/0/archive.conf > /dev/null",
        stdin: anything
      )
      expect { prog.create_archive_conf }.to hop("create_kek_pipe")
    end
  end

  describe "#create_kek_pipe" do
    it "creates kek pipe and hops to run_archive" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo mkfifo /var/storage/#{vm.inhost_name}/0/kek.pipe")
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo chown #{vm.inhost_name}:#{vm.inhost_name} /var/storage/#{vm.inhost_name}/0/kek.pipe")
      expect { prog.create_kek_pipe }.to hop("run_archive")
    end
  end

  describe "#run_archive" do
    let(:unit_name) { "archive_vm_#{vm.inhost_name}" }
    let(:archive_binary_path) { "/opt/vhost-block-backend/#{Config.vhost_block_backend_version}/archive" }
    let(:vhost_conf_path) { "/var/storage/#{vm.inhost_name}/0/vhost-backend.conf" }
    let(:archive_conf_path) { "/var/storage/#{vm.inhost_name}/0/archive.conf" }
    let(:kek_file_path) { "/var/storage/#{vm.inhost_name}/0/kek.pipe" }

    before do
      allow(prog).to receive(:frame).and_return({"backend_version" => Config.vhost_block_backend_version})
    end

    it "runs archive with kek and hops to wait_archive" do
      expect(vm.vm_host.sshable).to receive(:d_run).with(
        unit_name,
        archive_binary_path,
        "--config", vhost_conf_path,
        "--target-config", archive_conf_path,
        "--kek", kek_file_path,
        "--unlink-kek"
      )
      expect(vm.vm_host.sshable).to receive(:_cmd).with(
        "sudo tee #{kek_file_path} > /dev/null",
        stdin: "---\nkey: YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=\ninit_vector: YmJiYmJiYmJiYmJi\nmethod: aes256-gcm\nauth_data: dGVzdGRhdGE=\n",
        log: false
      )
      expect { prog.run_archive }.to hop("wait_archive")
    end
  end

  describe "#wait_archive" do
    let(:unit_name) { "archive_vm_#{vm.inhost_name}" }

    it "cleans up and pops on success" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("Succeeded")
      expect(vm.vm_host.sshable).to receive(:d_clean).with(unit_name)
      expect { prog.wait_archive }.to hop("mark_machine_image_ready")
    end

    it "naps if not started" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("NotStarted")
      expect { prog.wait_archive }.to nap(5)
    end

    it "naps if in progress" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("InProgress")
      expect { prog.wait_archive }.to nap(5)
    end

    it "raises error on failure" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("Failed")
      expect { prog.wait_archive }.to raise_error("Archive command failed")
    end

    it "logs and naps on unknown state" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("UnknownState")
      expect(Clog).to receive(:emit).with("got unknown state from daemonizer2 check: UnknownState")
      expect { prog.wait_archive }.to nap(60)
    end
  end

  describe "#write_kek_pipe" do
    it "writes kek data to pipe" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with(
        "sudo tee /var/storage/#{vm.inhost_name}/0/kek.pipe > /dev/null",
        stdin: "---\nkey: YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=\ninit_vector: YmJiYmJiYmJiYmJi\nmethod: aes256-gcm\nauth_data: dGVzdGRhdGE=\n",
        log: false
      )
      prog.write_kek_pipe
    end
  end

  describe "#mark_machine_image_ready" do
    before do
      expect(prog).to receive(:frame).and_return({"machine_image_id" => machine_image.id}).twice
    end

    it "updates the machine image and pops" do
      expect { prog.mark_machine_image_ready }.to exit({"msg" => "Machine Image created successfully"})
      expect(machine_image.reload.ready).to be true
    end
  end

  describe "helper methods" do
    before do
      allow(prog).to receive(:frame).and_return({"backend_version" => "v0.4.0"})
    end

    it "returns correct archive_binary_path" do
      expect(prog.archive_binary_path).to eq("/opt/vhost-block-backend/v0.4.0/archive")
    end

    it "returns correct root_dir_path" do
      expect(prog.root_dir_path).to eq("/var/storage/#{vm.inhost_name}/0")
    end

    it "returns correct archive_conf_path" do
      expect(prog.archive_conf_path).to eq("/var/storage/#{vm.inhost_name}/0/archive.conf")
    end

    it "returns correct vhost_conf_path" do
      expect(prog.vhost_conf_path).to eq("/var/storage/#{vm.inhost_name}/0/vhost-backend.conf")
    end

    it "returns correct kek_file_path" do
      expect(prog.kek_file_path).to eq("/var/storage/#{vm.inhost_name}/0/kek.pipe")
    end

    it "returns correct unit_name" do
      expect(prog.unit_name).to eq("archive_vm_#{vm.inhost_name}")
    end
  end
end
