# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Minio::MinioPoolNexus < Prog::Base
  subject_is :minio_pool

  def self.assemble(cluster_id, start_index, server_count, drive_count, storage_size_gib, vm_size)
    unless MinioCluster[cluster_id]
      fail "No existing cluster"
    end

    DB.transaction do
      id = MinioPool.generate_uuid

      minio_pool = MinioPool.create_with_id(id,
        cluster_id: cluster_id,
        start_index: start_index,
        server_count: server_count,
        drive_count: drive_count,
        storage_size_gib: storage_size_gib,
        vm_size: vm_size)

      minio_pool.server_count.times do |i|
        Prog::Minio::MinioServerNexus.assemble(minio_pool.id, minio_pool.start_index + i)
      end
      Strand.create_with_id(id, prog: "Minio::MinioPoolNexus", label: "wait_servers")
    end
  end

  def self.assemble_additional_pool(cluster_id, server_count, drive_count, storage_size_gib, vm_size)
    DB.transaction do
      unless MinioCluster[cluster_id]
        fail "No existing cluster"
      end

      start_index = MinioCluster[cluster_id].servers.max_by(&:index).index + 1
      st = assemble(cluster_id, start_index, server_count, drive_count, storage_size_gib, vm_size)
      st.subject.incr_add_additional_pool
      st
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_servers_destroyed"].include?(strand.label)
        hop_destroy
      end
    end
  end

  def cluster
    @cluster ||= minio_pool.cluster
  end

  label def wait_servers
    if minio_pool.servers.all? { it.strand.label == "wait" }
      when_add_additional_pool_set? do
        decr_add_additional_pool
        cluster.incr_reconfigure
      end

      hop_wait
    end

    nap 5
  end

  label def wait
    nap 6 * 60 * 60
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy
    minio_pool.servers.each(&:incr_destroy)

    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 5 unless minio_pool.servers.empty?

    minio_pool.destroy
    pop "pool destroyed"
  end
end
