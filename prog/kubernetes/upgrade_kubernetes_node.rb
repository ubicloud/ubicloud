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
    # TODO: Backup etcd
    # TODO: Extract logic into another prog
    # TODO: Maybe a health check?
    kubernetes_cluster.kubectl "drain #{old_vm.inhost_name} --ignore-daemonsets"

    hop_drop_old_node
  end

  label def drop_old_node
    # Only required for dev, as we use static IP, not the LB, as the hostname
    kubernetes_cluster.vms.each do |vm|
      vm.sshable.cmd("sudo sed -i 's/#{old_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/#{new_vm.ephemeral_net4.to_s.gsub(".", "\\.")}/g' /etc/hosts")
    end

    DB.run("DELETE FROM kubernetes_clusters_vm WHERE kubernetes_cluster_id = '#{kubernetes_cluster.id}' AND vm_id = '#{old_vm.id}'")
    kubernetes_cluster.reload

    # kubeadm reset is necessary only for etcd member removal, delete node doesn't remove etcd member
    old_vm.sshable.cmd("sudo kubeadm reset --force")

    # Alternative way to remove etcd member
    # members_csv = kubernetes_cluster.etcdctl "member list --write-out=simple"
    # # Output format: ID, Status, Name, Peer Addrs, Client Addrs, Is Learner
    # # Sample output:
    # # 74e084d9ca9ef0f1, started, vmccw3wj, https://10.10.77.0:2380, https://10.10.77.0:2379, false
    # # 816f35c8a559c6e6, started, vmk9jx11, https://10.10.161.0:2380, https://10.10.161.0:2379, false
    # # aaa02e88664278fb, started, vmxfpybj, https://10.10.192.0:2380, https://10.10.192.0:2379, false
    # # aec53d7596f5e7a6, started, vmgbd3qn, https://10.10.138.0:2380, https://10.10.138.0:2379, false

    # etcd_member_to_remove = members_csv.split("\n").map { _1.split(", ") }.find { _1[2] == old_vm.inhost_name }
    # kubernetes_cluster.etcdctl "member remove #{etcd_member_to_remove[0]}" unless etcd_member_to_remove.nil?

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
