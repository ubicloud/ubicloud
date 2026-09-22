# frozen_string_literal: true

class Prog::Minio::RecreateVm < Prog::Base
  subject_is :minio_server

  def self.assemble(minio_server_id)
    unless (minio_server = MinioServer[minio_server_id])
      fail "No existing minio server"
    end

    servers = JSON.parse(minio_server.client.admin_info.body)["servers"]
    unless servers.all? { |server| server["state"] == "online" && server["drives"].all? { it["state"] == "ok" && !it["healing"] } }
      fail "Minio cluster is not healthy"
    end

    DB.transaction do
      cluster = minio_server.cluster.lock!
      server_ids = cluster.servers_dataset.select(Sequel[:minio_server][:id])
      unless Semaphore.where(strand_id: server_ids, name: "initial_provisioning").empty?
        fail "Another minio server of the cluster is in provisioning"
      end

      # MinioServerNexus does not restart an unavailable server while this is set.
      minio_server.incr_initial_provisioning
      Strand.create(prog: "Minio::RecreateVm", label: "start", stack: [{"subject_id" => minio_server.id}])
    end
  end

  def vm
    @vm ||= minio_server.vm
  end

  label def start
    register_deadline(nil, 30 * 60)

    old_vm = minio_server.vm
    volumes = old_vm.vm_storage_volumes_dataset.order(:disk_index).all
    name = old_vm.name
    old_vm.update(name: "#{name}-old")

    new_vm = Prog::Vm::Nexus.assemble_with_sshable(
      old_vm.project_id,
      sshable_unix_user: old_vm.sshable.unix_user,
      unix_user: old_vm.unix_user,
      location_id: old_vm.location_id,
      name:,
      size: old_vm.display_size,
      arch: old_vm.arch,
      storage_volumes: volumes.map { {size_gib: it.size_gib, track_written: it.track_written} },
      boot_image: old_vm.boot_image,
      enable_ip4: true,
      private_subnet_id: minio_server.cluster.private_subnet_id,
      distinct_storage_devices: volumes.map(&:storage_device_id).uniq.length == volumes.length,
      force_host_id: old_vm.vm_host_id,
      keep_ip4: true,
    ).subject

    old_vm.assigned_vm_address.update(dst_vm_id: new_vm.id)
    minio_server.update(vm_id: new_vm.id)
    old_vm.incr_destroy

    hop_wait_vm
  end

  label def wait_vm
    nap 5 unless vm.strand.label == "wait"

    minio_server.incr_pin_net_threads
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => vm.unix_user}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:create_minio_user)
  end

  label def create_minio_user
    vm.sshable.cmd("sudo groupadd -f --system minio-user")
    vm.sshable.cmd("id -u minio-user || sudo useradd --no-create-home --system -g minio-user minio-user")

    hop_setup
  end

  label def setup
    bud Prog::Minio::SetupMinio, {}, :mount_data_disks
    bud Prog::Minio::SetupMinio, {}, :install_minio
    bud Prog::Minio::SetupMinio, {}, :configure_minio

    hop_wait_setup
  end

  label def wait_setup
    reap(:start_minio)
  end

  label def start_minio
    case vm.sshable.cmd("common/bin/daemonizer --check start_minio")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean start_minio")
      hop_wait_online
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'systemctl start minio' start_minio")
    end

    nap 1
  end

  label def wait_online
    server_data = minio_server.server_data
    nap 10 unless server_data["state"] == "online" && server_data["drives"].all? { it["state"] == "ok" }

    minio_server.decr_initial_provisioning
    pop "minio server vm is recreated"
  end
end
