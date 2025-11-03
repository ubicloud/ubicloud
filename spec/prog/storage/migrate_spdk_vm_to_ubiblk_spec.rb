# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::MigrateSpdkVmToUbiblk do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:vm_host) {
    vm_host = create_vm_host
    vbb = VhostBlockBackend.create(version: Config.vhost_block_backend_version, allocation_weight: 0, vm_host_id: vm_host.id)
    vm_host.add_vhost_block_backend(vbb)
    si = SpdkInstallation.create(version: "v1", allocation_weight: 100, vm_host_id: vm_host.id)
    vm_host.add_spdk_installation(si)
    vm_host
  }
  let(:vm) {
    vm_host_slice = VmHostSlice.create(name: "slicename", vm_host_id: vm_host.id, cores: 1, total_cpu_percent: 100, used_cpu_percent: 100, total_memory_gib: 4, used_memory_gib: 4, family: "standard")
    vm = create_vm(vm_host_id: vm_host.id, vm_host_slice_id: vm_host_slice.id)
    kek = StorageKeyEncryptionKey.create(
      algorithm: "aes-256-gcm", key: "key_1",
      init_vector: "iv_1", auth_data: "somedata"
    )
    dev = StorageDevice.create(
      name: "nvme0",
      total_storage_gib: 100,
      available_storage_gib: 80
    )
    bi = BootImage.create(name: "ubuntu-noble", version: "20220202", vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 3)
    volume = VmStorageVolume.create(boot: true,
      size_gib: 20,
      disk_index: 0,
      storage_device: dev,
      key_encryption_key_1_id: kek.id,
      vm_id: vm.id,
      use_bdev_ubi: true,
      boot_image_id: bi.id,
      spdk_installation_id: vm_host.spdk_installations.first.id)
    vm.add_vm_storage_volume(volume)
    vm
  }

  before do
    allow(prog).to receive(:vm).and_return(vm)
  end

  describe "#assemble" do
    it "fails because vm does not exist" do
      expect {
        described_class.assemble("a66aa247-1c7c-4a21-bd9b-e8abfcec6354")
      }.to raise_error("Vm does not exist")
    end

    it "fails because vm does not have exactly one VmStorageVolume" do
      expect {
        described_class.assemble(create_vm.id)
      }.to raise_error("This prog only supports Vms with exactly one disk")
    end

    it "fails if the vm has a ubiblk disk" do
      vm.vm_storage_volumes.first.update(vhost_block_backend_id: vm_host.vhost_block_backends.first.id, vring_workers: 1)
      expect {
        described_class.assemble(vm.id)
      }.to raise_error("Vm is already using Ubiblk")
    end

    it "fails is the underlying vmhost does not have a vhost block backend" do
      vm_host.vhost_block_backends.each(&:destroy)
      expect {
        described_class.assemble(vm.id)
      }.to raise_error("VmHost does not have the right vhost block backend installed")
    end

    it "creates the strand" do
      expect {
        described_class.assemble(vm.id)
      }.not_to raise_error
    end
  end

  describe "#stop_vm" do
    it "stops the vm and hops to wait_vm_stop" do
      expect(vm).to receive(:incr_stop)
      expect { prog.stop_vm }.to hop("wait_vm_stop")
    end
  end

  describe "wait_vm_stop" do
    it "naps if vm has not stopped yet" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("systemctl is-active #{vm.inhost_name}").and_return("")
      expect { prog.wait_vm_stop }.to nap(5)
    end

    it "hops to remove_spdk_controller if vm is inactive" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("systemctl is-active #{vm.inhost_name}").and_raise(Sshable::SshError.new("cmd", "inactive\n", "stderr", 3, nil))
      expect { prog.wait_vm_stop }.to hop("remove_spdk_controller")
    end
  end

  describe "#remove_spdk_controller" do
    it "stops the spdk controller" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/spdk-migration-helper remove-spdk-controller", stdin: prog.migration_script_params)
      expect { prog.remove_spdk_controller }.to hop("generate_vhost_backend_conf")
    end
  end

  describe "#ready_migration" do
    it "readies the migration" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo mv /var/storage/#{vm.inhost_name}/0/disk.raw /var/storage/#{vm.inhost_name}/0/disk.raw.bk")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo rm /var/storage/#{vm.inhost_name}/0/vhost.sock")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo mkfifo /var/storage/#{vm.inhost_name}/0/kek.pipe")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo chown #{vm.inhost_name}:#{vm.inhost_name} /var/storage/#{vm.inhost_name}/0/kek.pipe")
      expect { prog.ready_migration }.to hop("download_migration_binaries")
    end
  end

  describe "#generate_vhost_backend_conf" do
    it "generates the vhost backend conf" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/convert-encrypted-dek-to-vhost-backend-conf --encrypted-dek-file /var/storage/#{vm.inhost_name}/0/data_encryption_key.json --kek-file /dev/stdin --vhost-conf-output-file /var/storage/#{vm.inhost_name}/0/vhost-backend.conf --vm-name #{vm.inhost_name} --device nvme0", stdin: vm.storage_secrets.to_json)
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo chown #{vm.inhost_name}:#{vm.inhost_name} /var/storage/#{vm.inhost_name}/0/vhost-backend.conf")
      expect { prog.generate_vhost_backend_conf }.to hop("ready_migration")
    end
  end

  describe "#download_migration_binaries" do
    it "downloads the migration binary" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("curl -L -f -o /tmp/migrate https://github.com/ubicloud/ubiblk-migrate/releases/download/v0.2.0/migrate")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sha256sum /tmp/migrate | cut -d' ' -f1").and_return("6a73c44ef6ab03ede17186a814f80a174cbe5ed9cc9f7ae6f5f639a7ec97c4ac\n")
      expect(vm.vm_host.sshable).to receive(:cmd).with("chmod +x /tmp/migrate")
      expect { prog.download_migration_binaries }.to hop("migrate_from_spdk_to_ubiblk")
    end

    it "downloads the migration binary but sha256sum fails" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("curl -L -f -o /tmp/migrate https://github.com/ubicloud/ubiblk-migrate/releases/download/v0.2.0/migrate")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sha256sum /tmp/migrate | cut -d' ' -f1").and_return("wronghash\n")
      expect { prog.download_migration_binaries }.to nap(10)
    end
  end

  describe "#migrate_from_spdk_to_ubiblk" do
    let(:unit_name) { "migrate_from_spdk_to_ubiblk_#{vm.inhost_name}" }

    it "starts the migration if not already" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("NotStarted")
      expect(vm.vm_host.sshable).to receive(:d_run).with(unit_name, "/tmp/migrate", "-base-image=/var/storage/images/ubuntu-noble-20220202.raw", "-overlay-image=/var/storage/#{vm.inhost_name}/0/disk.raw.bk", "-output-image=/var/storage/#{vm.inhost_name}/0/disk.raw", "-kek-file=/var/storage/#{vm.inhost_name}/0/kek.pipe", "-vhost-backend-conf-file=/var/storage/#{vm.inhost_name}/0/vhost-backend.conf")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo tee /var/storage/#{vm.inhost_name}/0/kek.pipe > /dev/null", stdin: "---\nkey: key_1\ninit_vector: iv_1\nmethod: aes256-gcm\nauth_data: c29tZWRhdGE=\n", log: false)
      expect { prog.migrate_from_spdk_to_ubiblk }.to nap(5)
    end

    it "naps if the migration is in progress" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("InProgress")
      expect { prog.migrate_from_spdk_to_ubiblk }.to nap(5)
    end

    it "naps if the migration fails" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("Failed")
      expect { prog.migrate_from_spdk_to_ubiblk }.to nap(65536)
    end

    it "naps if daemonizer2 returns an unknown state" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("asdf")
      expect { prog.migrate_from_spdk_to_ubiblk }.to nap(65536)
    end

    it "cleans up and hops to the next stage" do
      expect(vm.vm_host.sshable).to receive(:d_check).with(unit_name).and_return("Succeeded")
      expect(vm.vm_host.sshable).to receive(:d_clean).with(unit_name)
      expect { prog.migrate_from_spdk_to_ubiblk }.to hop("create_ubiblk_systemd_unit")
    end
  end

  describe "#create_ubiblk_systemd_unit" do
    it "creates the systemd unit and hops to the next label" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo chown #{vm.inhost_name}:#{vm.inhost_name} /var/storage/#{vm.inhost_name}/0/disk.raw")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo host/bin/spdk-migration-helper create-vhost-backend-service-file", stdin: prog.migration_script_params)
      expect { prog.create_ubiblk_systemd_unit }.to hop("start_ubiblk_systemd_unit")
    end
  end

  describe "#start_ubiblk_systemd_unit" do
    it "starts the ubiblk systemd unit and hops to the next stage" do
      unit_name = "#{vm.inhost_name}-0-storage.service"
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo systemctl start #{unit_name}")
      expect(prog).to receive(:write_kek_pipe)
      expect { prog.start_ubiblk_systemd_unit }.to hop("start_vm")
    end
  end

  describe "#start_vm" do
    it "starts the vm" do
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo systemctl start #{vm.inhost_name}")
      expect { prog.start_vm }.to hop("update_vm_model")
    end
  end

  describe "#update_vm_model" do
    it "updates the vm to be identified as a ubiblk vm" do
      st = instance_double(Strand)
      expect(vm).to receive(:strand).and_return(st)
      expect(st).to receive(:update).with(label: "wait")
      expect(vm.vm_storage_volumes.first).to receive(:update).with(use_bdev_ubi: false, vhost_block_backend_id: vm_host.vhost_block_backends.first.id, vring_workers: 1, spdk_installation_id: nil)
      expect { prog.update_vm_model }.to hop("create_prep_json_file")
    end
  end

  describe "#create_prep_json_file" do
    it "creates the prep json file for proper cleanup of vm later" do
      expect(vm).to receive(:params_json).and_return("{}")
      expect(vm.vm_host.sshable).to receive(:cmd).with("sudo tee /vm/#{vm.inhost_name}/prep.json >/dev/null", stdin: "{}")
      expect { prog.create_prep_json_file }.to exit({"msg" => "Vm successfully migrated to ubiblk"})
    end
  end
end
