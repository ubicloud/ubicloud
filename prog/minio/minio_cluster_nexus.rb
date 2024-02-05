# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Minio::MinioClusterNexus < Prog::Base
  subject_is :minio_cluster

  semaphore :destroy, :reconfigure

  def self.assemble(project_id, cluster_name, location, admin_user,
    storage_size_gib, pool_count, server_count, drive_count, vm_size)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_vm_size(vm_size)
    Validation.validate_location(location, project.provider)
    Validation.validate_name(cluster_name)
    Validation.validate_minio_username(admin_user)

    DB.transaction do
      ubid = MinioCluster.generate_ubid
      root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
      root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)

      subnet_st = Prog::Vnet::SubnetNexus.assemble(
        Config.minio_service_project_id,
        name: "#{cluster_name}-subnet",
        location: location
      )
      minio_cluster = MinioCluster.create(
        name: cluster_name,
        location: location,
        admin_user: admin_user,
        admin_password: SecureRandom.urlsafe_base64(15),
        private_subnet_id: subnet_st.id,
        root_cert_1: root_cert_1,
        root_cert_key_1: root_cert_key_1,
        root_cert_2: root_cert_2,
        root_cert_key_2: root_cert_key_2
      ) { _1.id = ubid.to_uuid }
      minio_cluster.associate_with_project(project)

      per_pool_server_count = server_count / pool_count
      per_pool_drive_count = drive_count / pool_count
      per_pool_storage_size = storage_size_gib / pool_count
      pool_count.times do |i|
        start_index = i * per_pool_server_count
        Prog::Minio::MinioPoolNexus.assemble(minio_cluster.id, start_index, per_pool_server_count, per_pool_drive_count, per_pool_storage_size, vm_size)
      end

      Strand.create(prog: "Minio::MinioClusterNexus", label: "wait_pools") { _1.id = minio_cluster.id }
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_pools_destroyed"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def wait_pools
    register_deadline(:wait, 10 * 60)
    if minio_cluster.pools.all? { _1.strand.label == "wait" }
      # Start all the servers now
      minio_cluster.servers.each(&:incr_restart)
      hop_wait
    end
    nap 5
  end

  label def wait
    if minio_cluster.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    when_reconfigure_set? do
      hop_reconfigure
    end

    nap 30
  end

  label def refresh_certificates
    if OpenSSL::X509::Certificate.new(minio_cluster.root_cert_1).not_after < Time.now + 60 * 60 * 24 * 30 * 5
      minio_cluster.root_cert_1, minio_cluster.root_cert_key_1 = minio_cluster.root_cert_2, minio_cluster.root_cert_key_2
      minio_cluster.root_cert_2, minio_cluster.root_cert_key_2 = Util.create_root_certificate(common_name: "#{minio_cluster.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      minio_cluster.servers.map(&:incr_reconfigure)
    end

    minio_cluster.certificate_last_checked_at = Time.now
    minio_cluster.save_changes

    hop_wait
  end

  label def reconfigure
    decr_reconfigure
    minio_cluster.servers.map(&:incr_reconfigure)
    minio_cluster.servers.map(&:incr_restart)
    hop_wait
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    DB.transaction do
      decr_destroy
      minio_cluster.dissociate_with_project(minio_cluster.projects.first)
      minio_cluster.pools.each(&:incr_destroy)
    end
    hop_wait_pools_destroyed
  end

  label def wait_pools_destroyed
    nap 10 unless minio_cluster.pools.empty?
    DB.transaction do
      minio_cluster.private_subnet&.incr_destroy
      minio_cluster.destroy
    end

    pop "destroyed"
  end
end
