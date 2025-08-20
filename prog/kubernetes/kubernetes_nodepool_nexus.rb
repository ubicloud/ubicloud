# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  def self.assemble(name:, node_count:, kubernetes_cluster_id:, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless KubernetesCluster[kubernetes_cluster_id]
        fail "No existing cluster"
      end

      Validation.validate_kubernetes_worker_node_count(node_count)

      kn = KubernetesNodepool.create(name:, node_count:, kubernetes_cluster_id:, target_node_size:, target_node_storage_size_gib:)

      Strand.create_with_id(kn.id, prog: "Kubernetes::KubernetesNodepoolNexus", label: "start")
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
    register_deadline("wait", 120 * 60)
    when_start_bootstrapping_set? do
      hop_bootstrap_worker_vms
    end
    nap 10
  end

  label def bootstrap_worker_vms
    kubernetes_nodepool.node_count.times do
      bud Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster_id}
    end
    hop_wait_worker_node
  end

  label def wait_worker_node
    reap(:wait)
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 6 * 60 * 60
  end

  label def upgrade
    decr_upgrade

    node_to_upgrade = kubernetes_nodepool.vms.find do |vm|
      vm_version = kubernetes_nodepool.cluster.client(session: vm.sshable.connect).version
      vm_minor_version = vm_version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i
      cluster_minor_version = kubernetes_nodepool.cluster.version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i

      next false unless vm_minor_version && cluster_minor_version
      vm_minor_version == cluster_minor_version - 1
    end

    hop_wait unless node_to_upgrade

    bud Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id, "nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.cluster.id}
    hop_wait_upgrade
  end

  label def wait_upgrade
    reap(:upgrade)
  end

  label def destroy
    reap do
      decr_destroy

      kubernetes_nodepool.nodes.each(&:incr_destroy)
      kubernetes_nodepool.vms.each(&:incr_destroy)
      kubernetes_nodepool.remove_all_vms
      nap 5 unless kubernetes_nodepool.nodes.empty?
      kubernetes_nodepool.destroy
      pop "kubernetes nodepool is deleted"
    end
  end
end
