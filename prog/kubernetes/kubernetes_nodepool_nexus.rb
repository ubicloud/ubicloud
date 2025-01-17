# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  def self.assemble(name:, node_count:, kubernetes_cluster_id:)
    DB.transaction do
      unless KubernetesCluster[kubernetes_cluster_id]
        fail "No existing cluster"
      end

      kn = KubernetesNodepool.create(
        name: name,
        node_count: node_count,
        kubernetes_cluster_id: kubernetes_cluster_id
      )

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
    nap 30 unless kubernetes_nodepool.kubernetes_cluster.strand.label == "wait"
    register_deadline("wait", 120 * 60)
    hop_bootstrap_worker_vms
  end

  label def bootstrap_worker_vms
    hop_wait if kubernetes_nodepool.vms.count >= kubernetes_nodepool.node_count
    push Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster.id}
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 30
  end

  label def upgrade
    decr_upgrade

    # Pick a node to upgrade
    node_to_upgrade = kubernetes_nodepool.vms.find do |vm|
      # TODO: Put another check here to make sure the version we receive is either one version old or the correct version, just in case
      res = vm.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version")
      res.match(/Client Version: (v1\.\d\d)\.\d/).captures.first != kubernetes_nodepool.kubernetes_cluster.kubernetes_version
    end

    hop_wait unless node_to_upgrade

    push Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id, "nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster.id}
  end

  label def destroy
    kubernetes_nodepool.vms.each(&:incr_destroy)
    kubernetes_nodepool.remove_all_vms
    kubernetes_nodepool.destroy
    pop "kubernetes nodepool is deleted"
  end
end
