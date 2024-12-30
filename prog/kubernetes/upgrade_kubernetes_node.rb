# frozen_string_literal: true

class Prog::Kubernetes::UpgradeKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def old_vm
    @old_vm ||= Vm[frame.fetch("old_vm_id")]
  end

  def new_vm
    @new_vm ||= Vm[frame.fetch("new_vm_id")] || nil
  end

  label def start
    bud Prog::Kubernetes::ProvisionKubernetesControlPlaneNode

    hop_wait_new_node
  end

  label def wait_new_node
    res = reap

    donate if res.empty?

    set_frame("new_vm_id", res.first.exitval.fetch("vm_id"))

    hop_drain_old_node
  end

  label def drain_old_node
    kubernetes_cluster.kubectl "drain #{old_vm.inhost_name} --ignore-daemonsets"

    hop_drop_old_node
  end

  label def drop_old_node
    # Only required for dev, as we use static IP, not the LB, as the hostname
    kubernetes_cluster.vms.each do |vm|
      vm.sshable.cmd("sudo sed -i 's/#{old_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/#{new_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/g' /etc/hosts")
    end
    kubernetes_cluster.kubectl "delete node #{old_vm.inhost_name}"
  end
end
