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
      minio_cluster = MinioCluster.create_with_id(
        name: cluster_name,
        location: location,
        admin_user: admin_user,
        admin_password: SecureRandom.urlsafe_base64(15),
        target_total_storage_size_gib: storage_size_gib,
        target_total_pool_count: pool_count,
        target_total_server_count: server_count,
        target_total_drive_count: drive_count,
        target_vm_size: vm_size
      )
      minio_cluster.associate_with_project(project)

      Strand.create(prog: "Minio::MinioClusterNexus", label: "start") { _1.id = minio_cluster.id }
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_pools_destroyed"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def start
    register_deadline(:wait, 10 * 60)
    subnet_st = Prog::Vnet::SubnetNexus.assemble(
      Config.minio_service_project_id,
      name: "#{minio_cluster.name}-subnet",
      location: minio_cluster.location
    )
    minio_cluster.update(private_subnet_id: subnet_st.id)

    minio_cluster.target_total_pool_count.times do |i|
      Prog::Minio::MinioPoolNexus.assemble(minio_cluster.id, i * minio_cluster.per_pool_server_count, minio_cluster.per_pool_server_count, minio_cluster.per_pool_drive_count, minio_cluster.per_pool_storage_size)
    end

    hop_wait_pools
  end

  label def wait_pools
    if minio_cluster.pools.all? { _1.strand.label == "wait" }
      # Start all the servers now
      minio_cluster.servers.each(&:incr_restart)
      hop_configure_dns_records
    end
    nap 5
  end

  label def configure_dns_records
    minio_cluster.servers.each do |server|
      dns_zone&.insert_record(record_name: minio_cluster.hostname, type: "A", ttl: 10, data: server.vm.ephemeral_net4.to_s)
    end

    hop_wait
  end

  label def wait
    when_reconfigure_set? do
      hop_reconfigure
    end

    nap 30
  end

  label def reconfigure
    decr_reconfigure
    minio_cluster.servers.map(&:incr_reconfigure)
    minio_cluster.servers.map(&:incr_restart)
    hop_configure_dns_records
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    DB.transaction do
      decr_destroy
      dns_zone&.delete_record(record_name: minio_cluster.hostname)
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

  def dns_zone
    @@dns_zone ||= DnsZone.where(project_id: Config.minio_service_project_id, name: Config.minio_host_name).first
  end
end
