# frozen_string_literal: true

class Prog::Kubernetes::UpgradeKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def old_vm
    @old_vm ||= Vm[frame.fetch("old_vm_id")]
  end

  def new_vm
    @new_vm ||= Vm[frame.fetch("new_vm_id")] || nil
  end

  def kubernetes_nodepool
    @kubernetes_nodepool ||= KubernetesNodepool[frame.fetch("nodepool_id", nil)] || nil
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
    # TODO: Backup etcd
    # TODO: Extract drain&drop logic into another prog
    kubernetes_cluster.kubectl "drain #{old_vm.inhost_name} --ignore-daemonsets"

    hop_drop_old_node
  end

  label def drop_old_node
    # Only required for dev, as we use static IP, not the LB, as the hostname
    kubernetes_cluster.all_vms.each do |vm|
      vm.sshable.cmd("sudo sed -i 's/#{old_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/#{new_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/g' /etc/hosts")
    end

    if kubernetes_nodepool
      kubernetes_nodepool.remove_vm(old_vm)
    else
      kubernetes_cluster.remove_cp_vm(old_vm)
      kubernetes_cluster.reload
    end

    # TODO: Maybe some sanity check before?
    # kubeadm reset is necessary for etcd member removal, delete node itself doesn't remove node from the etcd member, hurting the etcd cluster health
    old_vm.sshable.cmd("sudo kubeadm reset --force")

    begin
      kubernetes_cluster.kubectl "delete node #{old_vm.inhost_name}"
    rescue Sshable::SshError => ex
      raise unless /nodes "#{old_vm.inhost_name}" not found/.match?(ex.stderr)
    end

    # TODO: Maybe a final health check?

    old_vm.incr_destroy
    pop "upgraded node"
  end
end
