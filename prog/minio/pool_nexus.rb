# frozen_string_literal: true

class Prog::Minio::PoolNexus < Prog::Base
  subject_is :minio_pool
  semaphore :destroy, :start
  def self.assemble(start_index, capacity, node_count, cluster_id, key)
    DB.transaction do
      pool = MinioPool.create(start_index: start_index, node_count: node_count, capacity: capacity, cluster_id: cluster_id)
      pool_st = Strand.create(prog: "Minio::PoolNexus", label: "wait_vm_creation") { _1.id = pool.id }

      node_count.times do
        vm_st = Prog::Vm::Nexus.assemble(key)
        MinioNode.create(
          pool_id: pool.id,
          capacity: capacity / node_count
        ) { _1.id = vm_st.id }
      end

      pool_st
    end
  end

  def wait_vm_creation
    # gotta wait for all vms to be created
    hop :bootstrap_rhizome if minio_pool.minio_node_dataset.eager(:vm).all? { |mn| mn.vm.display_state == "running" }
    nap
  end

  def bootstrap_rhizome
    bud_for_all(Prog::BootstrapRhizome, user: "ubi")
    hop :wait_bootstrap_rhizome
  end

  def wait_bootstrap_rhizome
    wait_buds_then_hop(:prep)
  end

  def prep
    bud_for_all(Prog::SetupMinioNode)
    hop :wait_prep
  end

  def wait_prep
    wait_buds_then_hop(:running)
  end

  def running
    when_destroy_set? do
      hop :destroy
    end
    nap 30
  end

  def destroy
    minio_pool.minio_node.each do |mn|
      mn.vm.incr_destroy
    end
    hop :wait_destroy
  end

  def wait_destroy
    if minio_pool.minio_node.all? { |mn| mn.vm.nil? }
      minio_pool.minio_node.map(&:delete)
      hop :destroyed
    end
    nap
  end

  def destroyed
    minio_pool.delete
    pop "Minio pool #{minio_pool.id} destroyed"
  end

  def bud_for_all(prog, user: nil)
    minio_pool.minio_node.each do |mn|
      if user
        bud prog, {subject_id: mn.id, user: user} 
      else
        bud prog, {subject_id: mn.id}
      end
    end
  end
end
