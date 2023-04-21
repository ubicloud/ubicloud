# frozen_string_literal: true

class Prog::Minio::ClusterNexus < Prog::Base
  semaphore :destroy
  def self.assemble(node_count, *args, **kwargs)
    DB.transaction do
      id = SecureRandom.uuid
      mc = MinioCluster.create() { _1.id = id}
      node_count.times do
        node_st = Prog::Minio::NodeNexus.assemble(mc, *args, **kwargs)
        node_st.update(parent_id: id)
      end
      Strand.create(prog: "Minio::ClusterNexus", label: "start") { _1.id = id }
    end
  end
  
  def start
    puts "hello"
    # probably there is a much better way to check this
    hop :setup_node_configs if strand.children.all?{ |c| c.label == "wait_minio_cluster" }
    donate
  end

  def setup_node_configs
    strand.children.each do |st|
      st.minio_node.incr_start_node
    end
    donate
  end
end