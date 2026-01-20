# frozen_string_literal: true

class Prog::Storage::ArchiveVm < Prog::Base
  subject_is :vm

  def self.assemble(vm_id)
    unless Config.storage_archive_access_key && Config.storage_archive_secret_key && Config.storage_archive_bucket
      fail "Storage archive credentials are not configured"
    end

    unless (vm = Vm[vm_id])
      fail "Vm does not exist"
    end

    unless vm.vm_storage_volumes.count == 1
      fail "This prog only supports Vms with exactly one disk"
    end

    unless vm.vm_storage_volumes.first.vhost_block_backend_id
      fail "Vm is not using Ubiblk"
    end

    unless vm.vm_host.vhost_block_backends.any?
      fail "VmHost does not have any vhost block backend installed"
    end

    backend_version = vm.vm_storage_volumes.first.vhost_block_backend_version
    archive_bin_path = "/opt/vhost-block-backend/#{backend_version}/archive"
    begin
      vm.vm_host.sshable.cmd("test -f :archive_bin_path", archive_bin_path:)
    rescue Sshable::SshError
      fail "Archive binary not found at #{archive_bin_path}"
    end

    Strand.create(
      prog: "Storage::ArchiveVm",
      label: "create_archive_conf",
      stack: [{
        "subject_id" => vm_id,
        "backend_version" => backend_version
      }]
    )
  end

  label def create_archive_conf
    conf = <<~YAML
      type: s3
      bucket: "#{Config.storage_archive_bucket}"
      prefix: "#{vm.inhost_name}"
      endpoint: "https://c8f0cfc00294455265aa09519fcca930.eu.r2.cloudflarestorage.com"
      region: "auto"
      credentials:
        access_key_id: #{Config.storage_archive_access_key}
        secret_access_key: #{Config.storage_archive_secret_key}
    YAML

    vm.vm_host.sshable.write_file(archive_conf_path, conf)
    hop_run_archive
  end

  label def run_archive
    vm.vm_host.sshable.d_run(unit_name, archive_binary_path, "--config", vhost_conf_path, "--target-config", archive_conf_path)
    hop_wait_archive
  end

  label def wait_archive
    state = vm.vm_host.sshable.d_check(unit_name)

    case state
    when "Succeeded"
      vm.vm_host.sshable.d_clean(unit_name)
      pop "Archive created successfully"
    when "NotStarted", "InProgress"
      nap 5
    else
      if state == "Failed"
        fail "Archive command failed"
      else
        Clog.emit("got unknown state from daemonizer2 check: #{state}")
        nap 60
      end
    end
  end

  def archive_binary_path
    "/opt/vhost-block-backend/#{frame["backend_version"]}/archive"
  end

  def root_dir_path
    "/var/storage/#{vm.inhost_name}/0"
  end

  def archive_conf_path
    "#{root_dir_path}/archive.conf"
  end

  def vhost_conf_path
    "#{root_dir_path}/vhost-backend.conf"
  end

  def unit_name
    "archive_vm_#{vm.inhost_name}"
  end
end
