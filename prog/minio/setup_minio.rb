# frozen_string_literal: true

class Prog::Minio::SetupMinio < Prog::Base
  subject_is :minio_server

  label def install_minio
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check install_minio")
    when "Succeeded"
      pop "minio is installed"
    when "Failed", "NotStarted"
      minio_server.vm.sshable.cmd("common/bin/daemonizer 'minio/bin/install_minio #{Config.minio_version}' install_minio")
    end
    nap 5
  end

  label def configure_minio
    def_minio = <<ECHO
MINIO_VOLUMES="#{minio_server.minio_volumes}"
MINIO_OPTS="--console-address :9001"
MINIO_ROOT_USER="#{minio_server.cluster.admin_user}"
MINIO_ROOT_PASSWORD="#{minio_server.cluster.admin_password}"
ECHO

    hosts = <<ECHO
#{minio_server.cluster.generate_etc_hosts_entry}
ECHO

    minio_server.vm.sshable.cmd("sudo tee -a /etc/default/minio", stdin: def_minio)
    minio_server.vm.sshable.cmd("sudo tee -a /etc/hosts", stdin: hosts)
    minio_server.vm.sshable.cmd("sudo chown -R minio-user:minio-user /etc/default/minio")

    pop "minio is configured"
  end

  label def mount_data_disks
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check format_disks")
    when "Succeeded"
      minio_server.vm.sshable.cmd("sudo mkdir -p /minio")
      minio_server.vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).all.each_with_index do |volume, i|
        minio_server.vm.sshable.cmd("sudo mkdir -p /minio/dat#{i + 1}")
        device_path = volume.device_path.shellescape
        minio_server.vm.sshable.cmd("sudo common/bin/add_to_fstab #{device_path} /minio/dat#{i + 1} xfs defaults 0 0")
        minio_server.vm.sshable.cmd("sudo mount #{device_path} /minio/dat#{i + 1}")
      end
      minio_server.vm.sshable.cmd("sudo chown -R minio-user:minio-user /minio")

      pop "data disks are mounted"
    when "Failed", "NotStarted"
      cmd = minio_server.vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).all.map do |volume|
        device_path = volume.device_path.shellescape
        "sudo mkfs --type xfs #{device_path}"
      end.join(" && ")
      minio_server.vm.sshable.cmd("common/bin/daemonizer '#{cmd}' format_disks")
    end

    nap 5
  end
end
