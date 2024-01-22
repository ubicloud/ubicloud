# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Minio::MinioServerNexus < Prog::Base
  subject_is :minio_server

  extend Forwardable
  def_delegators :minio_server, :vm

  semaphore :checkup, :destroy, :restart, :reconfigure

  def self.assemble(minio_pool_id, index)
    unless (minio_pool = MinioPool[minio_pool_id])
      fail "No existing pool"
    end

    DB.transaction do
      ubid = MinioServer.generate_ubid

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "minio-user",
        Config.minio_service_project_id,
        location: minio_pool.cluster.location,
        name: ubid.to_s,
        size: minio_pool.vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30}
        ] + Array.new(minio_pool.per_server_drive_count) { {encrypted: false, size_gib: (minio_pool.per_server_storage_size / minio_pool.per_server_drive_count).floor} },
        boot_image: "ubuntu-jammy",
        enable_ip4: true,
        private_subnet_id: minio_pool.cluster.private_subnet.id
      )

      minio_server = MinioServer.create(minio_pool_id: minio_pool_id, vm_id: vm_st.id, index: index) { _1.id = ubid.to_uuid }

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

    minio_server.dns_zone&.insert_record(record_name: cluster.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s)
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
      hop_wait
    end
    donate
  end

  label def wait
    when_checkup_set? do
      decr_checkup
      hop_unavailable if !available?
    end

    when_reconfigure_set? do
      bud Prog::Minio::SetupMinio, {}, :configure_minio
      hop_wait_reconfigure
    end

    when_restart_set? do
      decr_restart
      push self.class, frame, "minio_restart"
    end
    nap 10
  end

  label def wait_reconfigure
    decr_reconfigure
    reap
    if leaf?
      hop_wait
    end
    donate
  end

  label def minio_restart
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check restart_minio")
    when "Succeeded"
      minio_server.vm.sshable.cmd("common/bin/daemonizer --clean restart_minio")
      pop "minio server is restarted"
    when "Failed", "NotStarted"
      minio_server.vm.sshable.cmd("common/bin/daemonizer 'systemctl restart minio' restart_minio")
    end
    nap 1
  end

  label def unavailable
    register_deadline(:wait, 10 * 60)

    reap
    nap 5 unless strand.children.select { _1.prog == "Minio::MinioServerNexus" && _1.label == "minio_restart" }.empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, frame, :minio_restart
    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    DB.transaction do
      decr_destroy
      minio_server.dns_zone&.delete_record(record_name: cluster.hostname)
      minio_server.vm.sshable.destroy
      minio_server.vm.nics.each { _1.incr_destroy }
      minio_server.vm.incr_destroy
      minio_server.destroy
    end

    pop "minio server destroyed"
  end

  def available?
    client = Minio::Client.new(
      endpoint: minio_server.connection_string,
      access_key: minio_server.cluster.admin_user,
      secret_key: minio_server.cluster.admin_password
    )

    server_data = JSON.parse(client.admin_info.body)["servers"].find { _1["endpoint"] == minio_server.endpoint }
    server_data["state"] == "online" && server_data["drives"].all? { _1["state"] == "ok" }
  rescue
    false
  end
end
