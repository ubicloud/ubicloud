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
    nap 6 * 60 * 60
  end

  label def destroy
    kubernetes_node.vm.incr_destroy
    kubernetes_node.destroy
    pop "kubernetes node is deleted"
  end
end
