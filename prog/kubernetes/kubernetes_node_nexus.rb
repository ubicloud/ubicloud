# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodeNexus < Prog::Base
  subject_is :kubernetes_node

  def self.assemble(project_id, sshable_unix_user:, name:, location_id:, size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:, kubernetes_cluster_id:, kubernetes_nodepool_id: nil)
    DB.transaction do
      id = KubernetesNode.generate_uuid
      vm = Prog::Vm::Nexus.assemble_with_sshable(project_id, sshable_unix_user:, name:, location_id:,
        size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:).subject
      KubernetesNode.create_with_id(id, vm_id: vm.id, kubernetes_cluster_id:, kubernetes_nodepool_id:)
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
    unit_name = "drain_node_#{kubernetes_node.name}"
    sshable = kubernetes_node.kubernetes_cluster.sshable
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
      nap(60 * 60 * 24)
    end
  end

  label def remove_node_from_cluster
    kubernetes_node.kubernetes_cluster.client.delete_node(kubernetes_node.name)
    hop_destroy
  end

  label def destroy
    kubernetes_node.vm.incr_destroy
    kubernetes_node.destroy
    pop "kubernetes node is deleted"
  end
end
