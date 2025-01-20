# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, kubernetes_version:, private_subnet_id:, project_id:, location:, cp_node_count: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      unless ["v1.32", "v1.31"].include?(kubernetes_version)
        fail "Invalid Kubernetes Version"
      end

      # TODO: Validate subnet location if given
      # TODO: Validate subnet size if given
      # TODO: Create subnet if not given
      # TODO: Validate location
      # TODO: Move resources (vms, subnet, LB, etc.) into own project
      # TODO: Validate node count

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        cp_node_count: cp_node_count,
        private_subnet_id: private_subnet_id,
        location: location,
        project_id: project.id
      )

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
    register_deadline("wait", 120 * 60)
    hop_create_load_balancer
  end

  label def create_load_balancer
    load_balancer_st = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: "#{kubernetes_cluster.name}-apiserver",
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp",
      stack: LoadBalancer::Stack::DUAL
    )
    kubernetes_cluster.update(api_server_lb_id: load_balancer_st.id)

    hop_bootstrap_control_plane_vms
  end

  label def bootstrap_control_plane_vms
    nap 5 unless kubernetes_cluster.endpoint

    hop_wait if kubernetes_cluster.cp_vms.count >= kubernetes_cluster.cp_node_count

    push Prog::Kubernetes::ProvisionKubernetesNode
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 65536
  end

  label def upgrade
    # Note that the kubernetes_version should point to the next version we are targeting
    decr_upgrade

    # Pick a control plane node to upgrade
    node_to_upgrade = kubernetes_cluster.cp_vms.find do |vm|
      # TODO: Put another check here to make sure the version we receive is either one version old or the correct version, just in case
      res = vm.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf version")
      res.match(/Client Version: (v1\.\d\d)\.\d/).captures.first != kubernetes_cluster.kubernetes_version
    end

    # If CP nodes are upgraded, check worker nodes
    unless node_to_upgrade
      kubernetes_cluster.kubernetes_nodepools.each { _1.incr_upgrade }
      hop_wait # TODO: wait for upgrades to finish?
    end

    push Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id}
  end

  label def destroy
    kubernetes_cluster.api_server_lb.incr_destroy
    kubernetes_cluster.cp_vms.each(&:incr_destroy)
    kubernetes_cluster.remove_all_cp_vms
    kubernetes_cluster.kubernetes_nodepools.each { _1.incr_destroy }
    nap 5 unless kubernetes_cluster.kubernetes_nodepools.empty?
    kubernetes_cluster.destroy
    pop "kubernetes cluster is deleted"
  end
end
