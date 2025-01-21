# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, kubernetes_version:, project_id:, location:, cp_node_count: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      unless ["v1.32", "v1.31"].include?(kubernetes_version)
        fail "Invalid Kubernetes Version"
      end

      subnet = Prog::Vnet::SubnetNexus.assemble(
        Config.kubernetes_service_project_id,
        location: location,
        ipv4_range: "10.10.0.0/16" # TODO: a better way?
      ).subject

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
        private_subnet_id: subnet.id,
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
    hop_setup_network
  end

  label def setup_network
    # TODO: Set FW rules and wait

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
    nap 65536
  end

  label def destroy
    kubernetes_cluster.api_server_lb.incr_destroy
    kubernetes_cluster.cp_vms.each(&:incr_destroy)
    kubernetes_cluster.remove_all_cp_vms
    kubernetes_cluster.destroy
    pop "kubernetes cluster is deleted"
  end
end
