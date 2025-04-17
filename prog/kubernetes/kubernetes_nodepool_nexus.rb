# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  def self.assemble(name:, node_count:, kubernetes_cluster_id:, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless KubernetesCluster[kubernetes_cluster_id]
        fail "No existing cluster"
      end

      Validation.validate_kubernetes_worker_node_count(node_count)

      kn = KubernetesNodepool.create(name:, node_count:, kubernetes_cluster_id:, target_node_size:, target_node_storage_size_gib:)

      Strand.create(prog: "Kubernetes::KubernetesNodepoolNexus", label: "start") { it.id = kn.id }
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
    when_start_bootstrapping_set? do
      hop_create_services_load_balancer
    end
    nap 10
  end

  label def create_services_load_balancer
    hop_bootstrap_worker_vms if LoadBalancer[name: kubernetes_nodepool.cluster.services_load_balancer_name]

    custom_hostname_dns_zone_id = DnsZone[name: Config.kubernetes_service_hostname]&.id
    custom_hostname_prefix = if custom_hostname_dns_zone_id
      "#{kubernetes_nodepool.cluster.ubid.to_s[-10...]}-services"
    end
    Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_nodepool.cluster.private_subnet_id,
      name: kubernetes_nodepool.cluster.services_load_balancer_name,
      algorithm: "hash_based",
      # TODO: change the api to support LBs without ports
      # The next two fields will be later modified by the sync_kubernetes_services label
      # These are just set for passing the creation validations
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix:,
      stack: LoadBalancer::Stack::IPV4
    )

    hop_bootstrap_worker_vms
  end

  label def bootstrap_worker_vms
    kubernetes_nodepool.node_count.times do
      bud Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster_id}
    end
    hop_wait_worker_node
  end

  label def wait_worker_node
    reap
    hop_wait if leaf?
    donate
  end

  label def wait
    nap 6 * 60 * 60
  end

  label def destroy
    reap
    donate unless leaf?
    decr_destroy
    LoadBalancer[name: kubernetes_nodepool.cluster.services_load_balancer_name]&.incr_destroy
    kubernetes_nodepool.vms.each(&:incr_destroy)
    kubernetes_nodepool.remove_all_vms
    kubernetes_nodepool.destroy
    pop "kubernetes nodepool is deleted"
  end
end
