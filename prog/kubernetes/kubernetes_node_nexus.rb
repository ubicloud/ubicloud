# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodeNexus < Prog::Base
  subject_is :kubernetes_node

  def self.assemble(project_id, sshable_unix_user:, name:, location_id:, size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:, kubernetes_cluster_id:, kubernetes_nodepool_id: nil)
    DB.transaction do
      id = KubernetesNode.generate_uuid
      cluster = KubernetesCluster[kubernetes_cluster_id]

      exclude_host_ids = if kubernetes_nodepool_id || Config.allow_unspread_servers
        []
      else
        cluster.cp_vms_dataset
          .exclude(vm_host_id: nil)
          .unordered
          .distinct
          .select_map(:vm_host_id)
      end

      vm = Prog::Vm::Nexus.assemble_with_sshable(project_id, sshable_unix_user:, name:, location_id:,
        size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:,
        allow_private_subnet_in_other_project: true,
        exclude_host_ids:).subject

      KubernetesNode.create_with_id(id, vm_id: vm.id, kubernetes_cluster_id:, kubernetes_nodepool_id:)

      internal_firewall = kubernetes_nodepool_id ? cluster.internal_worker_vm_firewall : cluster.internal_cp_vm_firewall
      vm.add_vm_firewall(internal_firewall)

      Strand.create_with_id(id, prog: "Kubernetes::KubernetesNodeNexus", label: "start")
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  def cluster
    kubernetes_node.kubernetes_cluster
  end

  def nodepool
    kubernetes_node.kubernetes_nodepool
  end

  label def start
    hop_wait
  end

  label def wait
    when_retire_set? do
      hop_retire
    end
    nap 6 * 60 * 60
  end

  label def retire
    kubernetes_node.update(state: "draining")
    hop_drain
  end

  label def drain
    unit_name = "drain_node_#{kubernetes_node.name}"
    sshable = cluster.sshable
    case sshable.d_check(unit_name)
    when "Succeeded"
      hop_remove_node_from_cluster
    when "NotStarted"
      sshable.d_run(unit_name, "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
        "drain", kubernetes_node.name, "--ignore-daemonsets", "--delete-emptydir-data")
      nap 10
    when "InProgress"
      nap 10
    when "Failed"
      sshable.d_restart(unit_name)
      nap 10
    else
      register_deadline("destroy", 0)
      nap 3 * 60 * 60
    end
  end

  label def remove_node_from_cluster
    # kubeadm reset is necessary for etcd member removal, deleting the node itself
    # won't remove the node from the etcd cluster, hurting the etcd cluster health
    kubernetes_node.sshable.cmd("sudo kubeadm reset --force")

    if nodepool
      cluster.services_lb.detach_vm(kubernetes_node.vm)
    else
      cluster.api_server_lb.detach_vm(kubernetes_node.vm)
    end

    cluster.client.delete_node(kubernetes_node.name)

    hop_destroy
  end

  label def destroy
    kubernetes_node.vm.incr_destroy
    kubernetes_node.destroy
    cluster.incr_sync_internal_dns_config
    pop "kubernetes node is deleted"
  end
end
