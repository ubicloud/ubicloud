# frozen_string_literal: true

class Prog::Storage::MigrateSpdkVmToUbiblk < Prog::Base
  subject_is :vm

  def self.assemble(vm_id)
    unless (vm = Vm[vm_id])
      fail "Vm does not exist"
    end

    unless vm.vm_storage_volumes.count == 1
      fail "This prog only supports Vms with exactly one disk"
    end

    if vm.vm_storage_volumes.first.vhost_block_backend_id
      fail "Vm is already using Ubiblk"
    end

    unless vm.vm_host.vhost_block_backends.find { |b| b.version == Config.vhost_block_backend_version }
      fail "VmHost does not have the right vhost block backend installed"
    end

    Strand.create(
      prog: "Storage::MigrateSpdkVmToUbiblk",
      label: "stop_vm",
      stack: [{
        "subject_id" => vm_id
      }]
    )
  end

  label def stop_vm
    register_deadline(nil, 60 * 60)
    vm.incr_stop
    hop_wait_vm_stop
  end

  label def wait_vm_stop
    vm_state = begin
      vm.vm_host.sshable.cmd("systemctl is-active #{vm.inhost_name}")
    rescue Sshable::SshError => ex
      # systemctl returns exit code 3 when a unit is inactive but writes
      # the result to the stdout. based on the way sshable.cmd work,
      # we need to capture the exception and extract the stdout, otherwise
      # on non-zero exit codes, it wouldn't return the stdout directly.
      ex.stdout.strip
    end
    nap 5 unless vm_state == "inactive"
    hop_remove_spdk_controller
  end

  label def remove_spdk_controller
    vm.vm_host.sshable.cmd("sudo host/bin/spdk-migration-helper remove-spdk-controller", stdin: migration_script_params)
    hop_generate_vhost_backend_conf
  end

  label def generate_vhost_backend_conf
    vm.vm_host.sshable.cmd("sudo host/bin/convert-encrypted-dek-to-vhost-backend-conf --encrypted-dek-file #{root_dir_path}data_encryption_key.json --kek-file /dev/stdin --vhost-conf-output-file #{vhost_conf_path} --vm-name #{vm.inhost_name} --device #{vm.vm_storage_volumes.first.storage_device.name}", stdin: vm.storage_secrets.to_json)
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{vhost_conf_path}")
    hop_ready_migration
  end

  label def ready_migration
    vm.vm_host.sshable.cmd("sudo mv #{root_dir_path}disk.raw #{root_dir_path}disk.raw.bk")

    vm.vm_host.sshable.cmd("sudo rm #{root_dir_path}vhost.sock")

    vm.vm_host.sshable.cmd("sudo mkfifo #{kek_file_path}")
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{kek_file_path}")

    hop_download_migration_binaries
  end

  label def download_migration_binaries
    begin
      url = "https://github.com/ubicloud/ubiblk-migrate/releases/download/v0.2.0/migrate"
      expected_sha256 = "6a73c44ef6ab03ede17186a814f80a174cbe5ed9cc9f7ae6f5f639a7ec97c4ac"
      path = "/tmp/migrate"
      vm.vm_host.sshable.cmd("curl -L -f -o #{path} #{url}")
      actual_sha256 = vm.vm_host.sshable.cmd("sha256sum #{path} | cut -d' ' -f1").strip
      raise "SHA256 mismatch for #{path}: expected #{expected_sha256}, got #{actual_sha256}" unless actual_sha256 == expected_sha256
      vm.vm_host.sshable.cmd("chmod +x #{path}")
    rescue => e
      Clog.emit("encountered an issue while downloading migration binaries") { {exception: {message: e.message}} }
      nap 10
    end
    hop_migrate_from_spdk_to_ubiblk
  end

  label def migrate_from_spdk_to_ubiblk
    unit_name = "migrate_from_spdk_to_ubiblk_#{vm.inhost_name}"
    state = vm.vm_host.sshable.d_check(unit_name)
    case state
    when "Succeeded"
      vm.vm_host.sshable.d_clean(unit_name)
      hop_create_ubiblk_systemd_unit
    when "NotStarted"
      vm.vm_host.sshable.d_run(unit_name, "/tmp/migrate", "-base-image=#{base_image_path}", "-overlay-image=#{root_dir_path}disk.raw.bk", "-output-image=#{root_dir_path}disk.raw", "-kek-file=#{kek_file_path}", "-vhost-backend-conf-file=#{vhost_conf_path}")
      write_kek_pipe
      nap 5
    when "InProgress"
      nap 5
    else
      Clog.emit((state == "Failed") ? "could not migrate from spdk to ubiblk" : "got unknown state from daemonizer2 check: #{state}")
      nap 65536
    end
  end

  label def create_ubiblk_systemd_unit
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{root_dir_path}disk.raw")
    vm.vm_host.sshable.cmd("sudo host/bin/spdk-migration-helper create-vhost-backend-service-file", stdin: migration_script_params)
    hop_start_ubiblk_systemd_unit
  end

  label def start_ubiblk_systemd_unit
    disk_index = 0
    unit_name = "#{vm.inhost_name}-#{disk_index}-storage.service"
    vm.vm_host.sshable.cmd("sudo systemctl start #{unit_name}")
    # Disk encryption happens using DEKs (Data Encryption Keys). DEKs needs to be presented
    # to the hypervisor to run the Vm. Now in the case of a breach to a VmHost, we don't want
    # to give away the keys easily so we encrypt the DEK with another set of keys: KEKs (key encryption key)
    # We do not want to store the KEK permenantly on the disk since it defeats the purpose,
    # so we write it to a pipe and ubiblk systemd unit will read its content once and the kek is gone.
    write_kek_pipe
    hop_start_vm
  end

  label def start_vm
    vm.vm_host.sshable.cmd("sudo systemctl start #{vm.inhost_name}")
    hop_update_vm_model
  end

  label def update_vm_model
    DB.transaction do
      vm.strand.update(label: "wait")
      vm.vm_storage_volumes.first.update(use_bdev_ubi: false, vhost_block_backend_id: vm_host_vhost_block_backend.id, vring_workers: 1, spdk_installation_id: nil)
    end
    hop_create_prep_json_file
  end

  label def create_prep_json_file
    vm.vm_host.sshable.cmd("sudo tee /vm/#{vm.inhost_name}/prep.json >/dev/null", stdin: vm.params_json)
    pop "Vm successfully migrated to ubiblk"
  end

  def migration_script_params
    vsv = vm.vm_storage_volumes.first
    {
      "slice" => vm.vm_host_slice.name,
      "device" => vsv.storage_device.name,
      "vm_name" => vm.inhost_name,
      "encrypted" => true,
      "disk_index" => 0,
      "vhost_block_backend_version" => Config.vhost_block_backend_version,
      "max_read_mbytes_per_sec" => vsv.max_read_mbytes_per_sec,
      "max_write_mbytes_per_sec" => vsv.max_write_mbytes_per_sec,
      "spdk_version" => vsv.spdk_installation.version
    }.to_json
  end

  def root_dir_path
    "/var/storage/#{vm.inhost_name}/0/"
  end

  def kek_file_path
    "#{root_dir_path}kek.pipe"
  end

  def vhost_conf_path
    "#{root_dir_path}vhost-backend.conf"
  end

  def write_kek_pipe
    kek = vm.vm_storage_volumes.first.key_encryption_key_1
    kek_data = {
      "key" => kek.key.strip,
      "init_vector" => kek.init_vector.strip,
      "method" => "aes256-gcm",
      "auth_data" => Base64.strict_encode64(kek.auth_data)
    }
    vm.vm_host.sshable.cmd("sudo tee #{kek_file_path} > /dev/null", stdin: kek_data.to_yaml, log: false)
  end

  def base_image_path
    vm.vm_storage_volumes.first.boot_image.path
  end

  def vm_host_vhost_block_backend
    vm.vm_host.vhost_block_backends.find { |b| b.version == Config.vhost_block_backend_version }
  end
end
