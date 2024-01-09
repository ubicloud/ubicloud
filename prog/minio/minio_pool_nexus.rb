# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Minio::MinioPoolNexus < Prog::Base
  subject_is :minio_pool

  semaphore :destroy, :add_additional_pool

  def self.assemble(cluster_id, start_index, server_count, drive_count, storage_size)
    unless MinioCluster[cluster_id]
      fail "No existing cluster"
    end

    DB.transaction do
      ubid = MinioPool.generate_ubid

      minio_pool = MinioPool.create(
        cluster_id: cluster_id,
        start_index: start_index,
        server_count: server_count,
        drive_count: drive_count,
        storage_size_gib: storage_size
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Minio::MinioPoolNexus", label: "start") { _1.id = minio_pool.id }
    end
  end

  def self.assemble_additional_pool(cluster_id, server_count, drive_count, storage_size)
    DB.transaction do
      st = assemble(cluster_id, MinioCluster[cluster_id]&.target_total_server_count, server_count, drive_count, storage_size)
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

  label def start
    register_deadline(:wait, 10 * 60)
    minio_pool.server_count.times do |i|
      Prog::Minio::MinioServerNexus.assemble(minio_pool.id, minio_pool.start_index + i)
    end
    hop_wait_servers
  end

  label def wait_servers
    if minio_pool.servers.all? { _1.strand.label == "wait" }
      when_add_additional_pool_set? do
        decr_add_additional_pool
        cluster.incr_reconfigure
      end

      hop_wait
    end

    nap 5
  end

  label def wait
    nap 30
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy
    DB.transaction do
      minio_pool.servers.each(&:incr_destroy)
    end

    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 5 unless minio_pool.servers.empty?

    minio_pool.destroy
    pop "pool destroyed"
  end
end
