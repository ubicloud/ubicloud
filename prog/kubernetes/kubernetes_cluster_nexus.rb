# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster
  semaphore :destroy, :upgrade

  def self.assemble(name:, kubernetes_version:, private_subnet_id:, project_id:, location:, replica: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        private_subnet_id: UBID.to_uuid(private_subnet_id),
        location: location
      )

      kc.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { _1.id = kc.id }
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
    hop_create_infrastructure
  end

  label def create_infrastructure
    # Question: should we manage the subnet or let the customer decide which one we will use.
    hop_create_loadbalancer
  end

  label def create_loadbalancer
    hop_bootstrap_first_control_plane unless kubernetes_cluster.load_balancer.nil?

    load_balancer_st = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: "#{kubernetes_cluster.name}-apiserver",
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp"
    )
    kubernetes_cluster.update(load_balancer_id: load_balancer_st.id)
    hop_bootstrap_control_plane_vms
  end

  label def bootstrap_control_plane_vms
    nap 5 unless kubernetes_cluster.load_balancer.hostname

    hop_wait if kubernetes_cluster.vms.count >= kubernetes_cluster.replica

    push Prog::Kubernetes::ProvisionKubernetesControlPlaneNode
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 30
  end

  label def upgrade
    # Note that the kubernetes_version should point to the next version we are targeting

    # Pick a control plane node to upgrade
    node_to_upgrade = kubernetes_cluster.vms.first do |vm|
      vm.sshable.cmd("sudo kubectl ")
    end

    hop_wait unless node_to_upgrade

    push Prog::Kubernetes::UpgradeKubernetesNode, {"vm_id" => node_to_upgrade.id}
  end

  label def destroy
    kubernetes_cluster.load_balancer.incr_destroy
    kubernetes_cluster.vms.map(&:incr_destroy)
    # kubernetes_cluster.kubernetes_nodepools. how to delete child nodepool?
    kubernetes_cluster.projects.map { kubernetes_cluster.dissociate_with_project(_1) }
    pop "kubernetes cluster is deleted"
  end
end
