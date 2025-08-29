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
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check configure_minio")
    when "Succeeded"
      minio_server.vm.sshable.cmd("common/bin/daemonizer --clean configure_minio")
      pop "minio is configured"
    when "Failed", "NotStarted"
      server_url_config = minio_server.cluster.dns_zone ? "MINIO_SERVER_URL=\"#{minio_server.server_url}\"" : ""
      minio_config = <<ECHO
MINIO_VOLUMES="#{minio_server.minio_volumes}"
MINIO_OPTS="--console-address :9001"
MINIO_ROOT_USER="#{minio_server.cluster.admin_user}"
MINIO_ROOT_PASSWORD="#{minio_server.cluster.admin_password}"
#{server_url_config}
MINIO_STORAGE_CLASS_STANDARD="EC:#{[minio_server.pool.per_server_drive_count * minio_server.pool.servers.count / 2, 8].min}"
ECHO

      hosts = <<ECHO
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
#{minio_server.generate_etc_hosts_entry}
ECHO
      config_json = JSON.generate({
        minio_config: minio_config,
        hosts: hosts,
        cert: minio_server.cert,
        cert_key: minio_server.cert_key,
        ca_bundle: minio_server.cluster.root_certs
      })

      minio_server.vm.sshable.cmd("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config_json)
    end

    nap 5
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
