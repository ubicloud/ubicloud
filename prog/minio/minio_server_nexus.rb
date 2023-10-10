# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Minio::MinioServerNexus < Prog::Base
  subject_is :minio_server

  extend Forwardable
  def_delegators :minio_server, :vm

  semaphore :destroy

  def self.assemble(minio_pool_id, index)
    unless (minio_pool = MinioPool[minio_pool_id])
      fail "No existing pool"
    end

    DB.transaction do
      ssh_key = SshKey.generate

      vm_st = Prog::Vm::Nexus.assemble(
        ssh_key.public_key,
        Config.minio_service_project_id,
        location: minio_pool.cluster.location,
        size: minio_pool.cluster.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30}
        ] + Array.new(minio_pool.per_server_driver_count) { {encrypted: false, size_gib: (minio_pool.per_server_storage_size / minio_pool.per_server_driver_count).floor} },
        boot_image: "ubuntu-jammy",
        enable_ip4: true,
        unix_user: "minio-user",
        private_subnet_id: minio_pool.cluster.private_subnet.id
      )

      Sshable.create(
        unix_user: "minio-user",
        host: "temp_#{vm_st.id}",
        raw_private_key_1: ssh_key.keypair
      ) { _1.id = vm_st.id }

      minio_server = MinioServer.create_with_id(minio_pool_id: minio_pool_id, vm_id: vm_st.id, index: index)

      Strand.create(prog: "Minio::MinioServerNexus", label: "start") { _1.id = minio_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  def cluster
    @cluster ||= minio_server.cluster
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    vm.sshable.update(host: vm.ephemeral_net4)
    bud Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "minio-user"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_setup if leaf?
    donate
  end

  label def setup
    bud Prog::Minio::SetupMinio, {}, :mount_data_disks
    bud Prog::Minio::SetupMinio, {}, :install_minio
    bud Prog::Minio::SetupMinio, {}, :configure_minio
    hop_wait_setup
  end

  label def wait_setup
    reap
    if leaf?
      hop_minio_start
    end
    donate
  end

  label def minio_start
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check start_minio")
    when "Succeeded"
      hop_wait
    when "Failed", "NotStarted"
      minio_server.vm.sshable.cmd("common/bin/daemonizer 'systemctl start minio' start_minio")
    end
    nap 5
  end

  label def wait
    nap 10
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    DB.transaction do
      decr_destroy
      minio_server.vm.sshable.destroy
      minio_server.vm.nics.each { _1.incr_destroy }
      minio_server.vm.incr_destroy
      minio_server.destroy
    end

    pop "minio server destroyed"
  end
end
