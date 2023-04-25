# frozen_string_literal: true

class Prog::Minio::NodeNexus < Prog::Base
  semaphore :destroy, :start_node

  def self.assemble(cluster, *args, **kwargs)
    DB.transaction do
      puts "here it is"
      id = SecureRandom.uuid
      vm = Prog::Vm::Nexus.assemble(*args, **kwargs)
      st = Strand.create(prog: "Minio::NodeNexus", label: "start", stack: [{vm_id: vm.id, minio_cluster_id: cluster.id}]) { _1.id = id }
      vm.update(parent_id: id)
      pp "created node with id #{id}"
      pp "created vm with id #{vm.id}"
      puts vm.id
      st
    end
  end

  def minio_node
    @minio_node ||= MinioNode[strand.id]
  end
  
  def start
    hop :create_entities if vm.display_state == "running"
    donate
  end
  
  def create_entities
    Sshable.create(host: vm.ephemeral_net6.network.to_s) { _1.id = strand.id }
    @minio_node = MinioNode.create(vm_id: vm_id, cluster_id: minio_cluster_id) { _1.id = strand.id }
    hop :bootstrap_rhizome
  end
  
  def bootstrap_rhizome
    hop :install_minio if retval == "rhizome user bootstrapped and source installed"
    push Prog::BootstrapRhizome, {sshable_id: strand.id, user: "ubi"}
  end
  
  def install_minio
    minio_node.sshable.cmd("sudo bin/prep_minio.rb #{MinioCluster[minio_cluster_id].name}")
    hop :wait_minio_cluster
  end

  def wait_minio_cluster
    when_start_node_set? do
      hop :start_node
    end
    donate
  end

  def start_node
    # need to set /etc/hosts and config files and start the node
    puts "starting node"
    # set /etc/hosts
    pp "Node is this: #{@minio_node}"
    minio_node.sshable.cmd("sudo sh -c \"echo #{minio_node.generate_etc_hosts_entry.shellescape} | sudo tee -a /etc/hosts\"")
    # set config files
    minio_node.sshable.cmd("sudo bin/gen_minio_config.rb #{minio_node.node_name}")
    # start node
    minio_node.sshable.cmd("sudo systemctl start minio")

    decr_start_node
    hop :wait_minio_cluster
  end
end