# frozen_string_literal: true

class Prog::Kubernetes::UpgradeKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def old_node
    @old_node ||= KubernetesNode[frame.fetch("old_node_id")]
  end

  def new_node
    @new_node ||= KubernetesNode[frame.fetch("new_node_id")]
  end

  def kubernetes_nodepool
    @kubernetes_nodepool ||= KubernetesNodepool[frame.fetch("nodepool_id", nil)]
  end

  def before_run
    if kubernetes_cluster.strand.label == "destroy" && strand.label != "destroy"
      reap { pop "upgrade cancelled" }
    end
  end

  label def start
    new_frame = if kubernetes_nodepool
      {"nodepool_id" => kubernetes_nodepool.id}
    else
      {}
    end

    bud Prog::Kubernetes::ProvisionKubernetesNode, new_frame

    hop_wait_new_node
  end

  label def wait_new_node
    node_id = nil
    reaper = lambda do |child|
      node_id = child.exitval.fetch("node_id")
    end

    reap(reaper:) do
      # This will not work correctly if the strand has multiple children.
      # However, the strand has only has a single child created in start.
      update_stack({"new_node_id" => node_id})

      hop_upgrade_kubeadm
    end
  end

  label def upgrade_kubeadm
    hop_drain_old_node if kubernetes_nodepool
    hop_drain_old_node if kubernetes_cluster.kubeadm_recorded_minor_version == kubernetes_cluster.version

    state = new_node.vm.sshable.d_check("kubeadm_upgrade_apply")
    case state
    when "Succeeded"
      hop_drain_old_node
    when "NotStarted"
      new_node.vm.sshable.d_run(
        "kubeadm_upgrade_apply",
        "bash", "-c",
        "sudo kubeadm upgrade apply --yes $(kubeadm version -o short)",
      )
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit((state == "Failed") ? "could not run kubeadm upgrade apply" : "got unknown state from daemonizer2 check: #{state}")
      nap 65536
    end
  end

  label def drain_old_node
    old_node.incr_retire
    hop_wait_for_drain
  end

  label def wait_for_drain
    nap 5 if old_node
    hop_destroy
  end

  label def destroy
    pop "upgraded node"
  end
end
