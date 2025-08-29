# frozen_string_literal: true

class Prog::Kubernetes::UpgradeKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def old_node
    @old_node ||= KubernetesNode[frame.fetch("old_node_id")]
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
      current_frame = strand.stack.first
      # This will not work correctly if the strand has multiple children.
      # However, the strand has only has a single child created in start.
      current_frame["new_node_id"] = node_id
      strand.modified!(:stack)

      hop_drain_old_node
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
