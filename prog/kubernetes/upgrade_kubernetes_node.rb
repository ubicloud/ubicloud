# frozen_string_literal: true

class Prog::Kubernetes::UpgradeKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def old_vm
    @old_vm ||= Vm[frame.fetch("old_vm_id")]
  end

  def new_vm
    @new_vm ||= Vm[frame.fetch("new_vm_id")]
  end

  def kubernetes_nodepool
    @kubernetes_nodepool ||= KubernetesNodepool[frame.fetch("nodepool_id", nil)]
  end

  def before_run
    if kubernetes_cluster.strand.label == "destroy" && strand.label != "destroy"
      reap
      donate unless leaf?
      pop "upgrade cancelled"
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
    res = reap
    donate if res.empty?

    current_frame = strand.stack.first
    current_frame["new_vm_id"] = res.first.exitval.fetch("vm_id")
    strand.modified!(:stack)

    hop_drain_old_node
  end

  label def drain_old_node
    register_deadline("remove_old_node_from_cluster", 60 * 60)

    vm = kubernetes_cluster.cp_vms.last
    case vm.sshable.d_check("drain_node")
    when "Succeeded"
      hop_remove_old_node_from_cluster
    when "NotStarted"
      vm.sshable.d_run("drain_node", "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
        "drain", old_vm.name, "--ignore-daemonsets", "--delete-emptydir-data")
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
    if kubernetes_nodepool
      kubernetes_nodepool.remove_vm(old_vm)
    else
      kubernetes_cluster.remove_cp_vm(old_vm)
      kubernetes_cluster.api_server_lb.detach_vm(old_vm)
    end

    # kubeadm reset is necessary for etcd member removal, delete node itself
    # doesn't remove node from the etcd member, hurting the etcd cluster health
    old_vm.sshable.cmd("sudo kubeadm reset --force")

    hop_delete_node_object
  end

  label def delete_node_object
    res = kubernetes_cluster.client.delete_node(old_vm.name)
    fail "delete node object failed: #{res}" unless res.exitstatus.zero?
    hop_destroy_node
  end

  label def destroy_node
    old_vm.incr_destroy
    pop "upgraded node"
  end
end
