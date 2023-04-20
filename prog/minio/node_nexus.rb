# frozen_string_literal: true

class Prog::Minio::NodeNexus < Prog::Base
    semaphore :destroy
    def self.assemble(cluster, *args, **kwargs)
        DB.transaction do
            id = SecureRandom.uuid
            vm = Prog::Vm::Nexus.assemble(*args, **kwargs)
            st = Strand.create(prog: "Minio::NodeNexus", label: "start", stack: [{vm_id: vm.id, minio_cluster_id: cluster.id}]) { _1.id = id }
            vm.update(parent_id: id)
            st
        end
    end

    def start
        puts "hellooo"
        hop :create_entities if vm.display_state == "running"
        donate
    end

    def create_entities
        puts "arrived to here"     
        Sshable.create(host: vm.ephemeral_net6.network.to_s) { _1.id = strand.id }
        MinioNode.create(vm_id: vm_id, cluster_id: minio_cluster_id) { _1.id = strand.id }
        hop :bootstrap_rhizome
    end

    def bootstrap_rhizome
        hop :install_minio if retval == "rhizome user bootstrapped and source installed"
        push Prog::BootstrapRhizome, {sshable_id: strand.id, user: "ubi"}
    end

    def install_minio
        donate
    end
end