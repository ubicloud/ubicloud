# frozen_string_literal: true

class Prog::Minio::ClusterNexus < Prog::Base
  subject_is :minio_cluster
  semaphore :destroy

  def self.assemble(name, pool_count, server_count, capacity, key)
    DB.transaction do
      # Calculate the number of servers for each pool
      server_counts = calculate_server_counts_per_pool(pool_count, server_count)
  
      cluster = MinioCluster.create(name: name, pool_count: pool_count, capacity: capacity)
      cluster_st = Strand.create(prog: "Minio::ClusterNexus", label: "wait_pool_creation") { _1.id = cluster.id }
  
      start_index = 1
      server_counts.each do |pool_server_count|
        pool_st = Prog::Minio::PoolNexus.assemble(
          start_index,
          capacity / pool_count,
          pool_server_count,
          cluster.id,
          key
        )
        pool_st.update(parent_id: cluster_st.id)
        start_index += pool_server_count
      end
  
      cluster_st
    end
  end  

  def self.calculate_server_counts_per_pool(pool_count, server_count)
    # Calculate the number of servers for the first pool
    first_pool_server_count = (server_count.to_f / pool_count).ceil
  
    # Calculate the number of remaining servers
    remaining_servers = server_count - first_pool_server_count
  
    # Create an array to store the number of servers for each pool
    server_counts = [first_pool_server_count]
  
    # Divide the remaining servers as evenly as possible across the remaining pools
    (pool_count - 1).times do
      server_count = [remaining_servers / (pool_count - server_counts.size), 1].max
      server_counts << server_count
      remaining_servers -= server_count
    end
  
    server_counts
  end

  def wait_pool_creation
    # gotta wait for all pools to be created
    if minio_cluster.minio_pool.all? { |p| p.strand.label == "running" }
      hop :running
    end

    nap
  end

  def running
    when_destroy_set? do
      hop :destroy
    end

    nap 30
  end

  def destroy
    minio_cluster.minio_pool.each do |p|
      p.incr_destroy
    end
    hop :wait_destroy
  end

  def wait_destroy
    hop :destroyed if minio_cluster.minio_pool.empty?
    nap
  end

  def destroyed
    minio_cluster.delete
    pop "Minio cluster destroyed"
  end
end
