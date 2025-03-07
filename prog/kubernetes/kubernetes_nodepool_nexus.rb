# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  def self.assemble(name:, node_count:, kubernetes_cluster_id:, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless KubernetesCluster[kubernetes_cluster_id]
        fail "No existing cluster"
      end

      kn = KubernetesNodepool.create(name:, node_count:, kubernetes_cluster_id:, target_node_size:, target_node_storage_size_gib:)

      Strand.create(prog: "Kubernetes::KubernetesNodepoolNexus", label: "start") { _1.id = kn.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    nap 30 unless kubernetes_nodepool.cluster.strand.label == "wait"
    register_deadline("wait", 120 * 60)
    hop_bootstrap_worker_vms
  end

  label def bootstrap_worker_vms
    hop_wait if kubernetes_nodepool.vms.count >= kubernetes_nodepool.node_count
    bud Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster_id}
    hop_wait_worker_node
  end

  label def wait_worker_node
    reap
    hop_bootstrap_worker_vms if leaf?
    donate
  end

  label def wait
    nap 65536
  end

  label def destroy
    kubernetes_nodepool.vms.each(&:incr_destroy)
    kubernetes_nodepool.remove_all_vms
    kubernetes_nodepool.destroy
    pop "kubernetes nodepool is deleted"
  end
end
