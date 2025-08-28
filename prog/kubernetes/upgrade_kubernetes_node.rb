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
      current_frame = strand.stack.first
      # This will not work correctly if the strand has multiple children.
      # However, the strand has only has a single child created in start.
      current_frame["new_node_id"] = node_id
      strand.modified!(:stack)

      hop_drain_old_node
    end
  end

  label def drain_old_node
    register_deadline("remove_old_node_from_cluster", 60 * 60)

    vm = kubernetes_cluster.cp_vms.last
    case vm.sshable.d_check("drain_node")
    when "Succeeded"
      hop_remove_old_node_from_cluster
    when "NotStarted"
      vm.sshable.d_run("drain_node", "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
        "drain", old_node.name, "--ignore-daemonsets", "--delete-emptydir-data")
      nap 10
    when "InProgress"
      nap 10
    when "Failed"
      vm.sshable.d_restart("drain_node")
      nap 10
    end
    nap 60 * 60
  end

  label def remove_old_node_from_cluster
    vm = old_node.vm
    unless kubernetes_nodepool
      kubernetes_cluster.api_server_lb.detach_vm(vm)
    end
    # kubeadm reset is necessary for etcd member removal, delete node itself
    # doesn't remove node from the etcd member, hurting the etcd cluster health
    vm.sshable.cmd("sudo kubeadm reset --force")

    hop_delete_node_object
  end

  label def delete_node_object
    res = kubernetes_cluster.client(session: kubernetes_cluster.nodes.last.sshable.connect).delete_node(old_node.name)
    fail "delete node object failed: #{res}" unless res.exitstatus.zero?
    hop_destroy_node
  end

  label def destroy_node
    old_node.incr_destroy
    pop "upgraded node"
  end
end
