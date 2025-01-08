# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool
  semaphore :destroy, :upgrade

  def self.assemble(name:, kubernetes_version:, project_id:, location:, replica:, kubernetes_cluster_id:)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kn = KubernetesNodepool.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        location: location,
        kubernetes_cluster_id: kubernetes_cluster_id
      )

      kn.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesNodepoolNexus", label: "start") { _1.id = kn.id }
    end
  end

  def set_frame(key, value)
    current_frame = strand.stack.first
    current_frame[key] = value
    strand.modified!(:stack)
    strand.save_changes
  end

  def set_current_vm(id)
    set_frame("current_vm", id)
  end

  def current_vm
    Vm[frame["current_vm"]]
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
    bootstrap_worker_vms
  end

  label def bootstrap_worker_vms
    hop_wait if kubernetes_nodepool.vms.count >= kubernetes_nodepool.replica
    push Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster.id}
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 30
  end

  label def upgrade
    # Note that the kubernetes_version should point to the next version we are targeting
    decr_upgrade

    # Pick a node to upgrade
    node_to_upgrade = kubernetes_nodepool.vms.find do |vm|
      # TODO: Put another check here to make sure the version we receive is either one version old or the correct version, just in case
      res = vm.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version")
      res.match(/Client Version: (v1\.\d\d)\.\d/).captures.first != kubernetes_nodepool.kubernetes_version
    end

    hop_wait unless node_to_upgrade

    push Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id, "nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster.id}
  end

  label def destroy
    kubernetes_nodepool.vms.each(&:incr_destroy)
    kubernetes_nodepool.projects.map { kubernetes_nodepool.dissociate_with_project(_1) }
    kubernetes_nodepool.destroy
    pop "kubernetes nodepool is deleted"
  end
end
