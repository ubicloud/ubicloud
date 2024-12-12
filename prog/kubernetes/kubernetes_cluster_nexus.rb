# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster
  semaphore :destroy

  def self.assemble(name:, kubernetes_version:, private_subnet_id:, project_id:, location:, replica: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        private_subnet_id: UBID.to_uuid(private_subnet_id),
        location: location
      )

      kc.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { _1.id = kc.id }
    end
  end

  label def start
    hop_create_infrastructure
  end

  label def create_infrastructure
    hop_create_loadbalancer
  end

  label def create_loadbalancer
    load_balancer_st = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: "#{kubernetes_cluster.name}-apiserver",
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "https",
      stack: LoadBalancer::Stack::IPV4
    )
    kubernetes_cluster.load_balancer_id = load_balancer_st.id
    kubernetes_cluster.update_changes
    hop_wait
  end

  label def bootstrap_first_vm
  end

  label def wait
    nap 30
  end

  label def destroy
    decr_destroy

    kubernetes_cluster.load_balancer.incr_destroy
    pop "kubernetes cluster is deleted"
  end
end
