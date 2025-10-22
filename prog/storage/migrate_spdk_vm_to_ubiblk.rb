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

    unless vm.vm_storage_volumes.first.use_bdev_ubi
      fail "Vm is already using Ubiblk"
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
    params = {
      "vm_name" => vm.inhost_name,
      "disk_index" => 0
    }
    vm.vm_host.sshable.cmd("sudo host/bin/remove-spdk-controller", stdin: params.to_json)
    hop_ready_migration
  end

  label def ready_migration
    vm.vm_host.sshable.cmd("sudo mv #{root_dir_path}disk.raw #{root_dir_path}disk.raw.bk")

    vm.vm_host.sshable.cmd("sudo rm #{root_dir_path}vhost.sock")

    vm.vm_host.sshable.cmd("sudo mkfifo #{kek_file_path}")
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{kek_file_path}")

    hop_generate_vhost_backend_conf
  end

  label def generate_vhost_backend_conf
    vm.vm_host.sshable.cmd("sudo host/bin/convert-encrypted-dek-to-vhost-backend-conf --encrypted-dek-file #{root_dir_path}data_encryption_key.json --kek-file /dev/stdin --vhost-conf-output-file #{vhost_conf_path} --vm-name #{vm.inhost_name}", stdin: vm.storage_secrets.to_json)
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{vhost_conf_path}")
    hop_download_migration_binaries
  end

  label def download_migration_binaries
    [
      ["https://github.com/ubicloud/ubiblk-migrate/releases/download/v0.1.0-xts/xts", "7f77c282f1261c7535d44a1c3a72775cf57b6f01b8265c86998f56cc1a0067fb", "/tmp/xts"],
      ["https://github.com/ubicloud/ubiblk-migrate/releases/download/v0.1.0/migrate", "691fac8a5b070a61c21aaba7fa0d6682f20af656f392b80820db19864952f063", "/tmp/migrate"]
    ].each do |url, expected_sha256, path|
      vm.vm_host.sshable.cmd("curl -L -f -o #{path} #{url}")
      actual_sha256 = vm.vm_host.sshable.cmd("sha256sum #{path} | cut -d' ' -f1").strip
      raise "SHA256 mismatch for #{path}: expected #{expected_sha256}, got #{actual_sha256}" unless actual_sha256 == expected_sha256
      vm.vm_host.sshable.cmd("chmod +x #{path}")
    rescue => e
      Clog.emit("encountered an issue while downloading migration binaries") { {exception: {message: e.message}} }
      nap 10
    end
    hop_decrypt_spdk_disk
  end

  label def decrypt_spdk_disk
    unit_name = "decrypt_spdk_disk_#{vm.inhost_name}"
    state = vm.vm_host.sshable.d_check(unit_name)
    case state
    when "Succeeded"
      vm.vm_host.sshable.d_clean(unit_name)
      hop_migrate_from_spdk_to_ubiblk
    when "NotStarted"
      vm.vm_host.sshable.d_run(unit_name, "/tmp/xts", "--kek", kek_file_path, "--config", vhost_conf_path, "--action", "decode", "#{root_dir_path}disk.raw.bk", "#{root_dir_path}unencrypted-spdk-disk.raw")
      write_kek_pipe
      nap 15
    when "InProgress"
      nap 15
    else
      Clog.emit((state == "Failed") ? "could not decrypt spdk disk" : "got unknown state from daemonizer2 check: #{state}")
      nap 65536
    end
  end

  label def migrate_from_spdk_to_ubiblk
    unit_name = "migrate_from_spdk_to_ubiblk_#{vm.inhost_name}"
    state = vm.vm_host.sshable.d_check(unit_name)
    case state
    when "Succeeded"
      vm.vm_host.sshable.d_clean(unit_name)
      hop_encrypt_ubiblk_disk
    when "NotStarted"
      vm.vm_host.sshable.d_run(unit_name, "/tmp/migrate", "-base-image=#{BootImage[name: vm.boot_image].path}", "-overlay-image=#{root_dir_path}unencrypted-spdk-disk.raw", "-output-image=#{root_dir_path}unencrypted-ubiblk-disk.raw")
      nap 15
    when "InProgress"
      nap 15
    else
      Clog.emit((state == "Failed") ? "could not migrate from spdk to ubiblk" : "got unknown state from daemonizer2 check: #{state}")
      nap 65536
    end
  end

  label def encrypt_ubiblk_disk
    unit_name = "encrypt_ubiblk_disk_#{vm.inhost_name}"
    state = vm.vm_host.sshable.d_check(unit_name)
    case state
    when "Succeeded"
      vm.vm_host.sshable.d_clean(unit_name)
      hop_cleanup_temporary_images
    when "NotStarted"
      vm.vm_host.sshable.d_run(unit_name, "/tmp/xts", "--kek", kek_file_path, "--config", vhost_conf_path, "--action", "encode", "#{root_dir_path}unencrypted-ubiblk-disk.raw", "#{root_dir_path}disk.raw")
      write_kek_pipe
      nap 15
    when "InProgress"
      nap 15
    else
      Clog.emit((state == "Failed") ? "could not encrypt disk" : "got unknown state from daemonizer2 check: #{state}")
      nap 65536
    end
  end

  label def cleanup_temporary_images
    vm.vm_host.sshable.cmd("sudo rm #{root_dir_path}unencrypted-spdk-disk.raw #{root_dir_path}unencrypted-ubiblk-disk.raw")
    vm.vm_host.sshable.cmd("sudo chown #{vm.inhost_name}:#{vm.inhost_name} #{root_dir_path}disk.raw")
    hop_create_ubiblk_systemd_unit
  end

  label def create_ubiblk_systemd_unit
    params = {
      "slice" => vm.vm_host_slice.name,
      "device" => vm.vm_storage_volumes.first.storage_device.name,
      "vm_name" => vm.inhost_name,
      "encrypted" => true,
      "disk_index" => 0,
      "vhost_block_backend_version" => "v0.2.1",
      "max_read_mbytes_per_sec" => vm.vm_storage_volumes.first.max_read_mbytes_per_sec,
      "max_write_mbytes_per_sec" => vm.vm_storage_volumes.first.max_write_mbytes_per_sec
    }
    vm.vm_host.sshable.cmd("sudo host/bin/setup-vhost-backend-systemd-unit", stdin: params.to_json)
    hop_start_ubiblk_systemd_unit
  end

  label def start_ubiblk_systemd_unit
    disk_index = 0
    unit_name = "#{vm.inhost_name}-#{disk_index}-storage.service"
    vm.vm_host.sshable.cmd("sudo systemctl enable #{unit_name}")
    vm.vm_host.sshable.cmd("sudo systemctl start #{unit_name}")
    write_kek_pipe
    hop_start_vm
  end

  label def start_vm
    vm.vm_host.sshable.cmd("sudo systemctl start #{vm.inhost_name}")
    hop_wait
  end

  label def wait
    nap 10000
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
    vm_storage_volume = vm.vm_storage_volumes.first
    kek_data = {
      "key" => vm_storage_volume.key_encryption_key_1.key.strip,
      "init_vector" => vm_storage_volume.key_encryption_key_1.init_vector.strip,
      "method" => "aes256-gcm",
      "auth_data" => Base64.strict_encode64(vm_storage_volume.key_encryption_key_1.auth_data)
    }
    vm.vm_host.sshable.cmd("sudo tee #{kek_file_path} > /dev/null", stdin: kek_data.to_yaml, log: false)
  end

  def storage_volume_params
    {
      "slice" => vm.vm_host_slice.name,
      "device" => vm.vm_storage_volumes.first.storage_device.name,
      "vm_name" => vm.inhost_name,
      "encrypted" => true,
      "disk_index" => 0,
      "vhost_block_backend_version" => "v0.2.1",
      "max_read_mbytes_per_sec" => vm.vm_storage_volumes.first.max_read_mbytes_per_sec,
      "max_write_mbytes_per_sec" => vm.vm_storage_volumes.first.max_write_mbytes_per_sec
    }
  end
end
