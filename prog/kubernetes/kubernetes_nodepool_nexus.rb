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
    nap 30 unless kubernetes_nodepool.cluster.strand.label == "wait_nodes"
    register_deadline("wait", 120 * 60)
    hop_create_services_load_balancer
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
    hop_wait if kubernetes_nodepool.vms.count >= kubernetes_nodepool.node_count
    bud Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.kubernetes_cluster_id}
    hop_wait_worker_node
  end

  label def wait_worker_node
    reap
    hop_bootstrap_worker_vms if leaf?
    donate
  end

  label def wait
    when_upgrade_set? do
      hop_upgrade
    end
    nap 6 * 60 * 60
  end

  label def upgrade
    decr_upgrade

    node_to_upgrade = kubernetes_nodepool.vms.find do |vm|
      # TODO: Put another check here to make sure the version we receive is either one version old or the correct version, just in case
      vm_version = kubernetes_nodepool.cluster.client(session: vm.sshable.start_fresh_session).version
      vm_version != kubernetes_nodepool.cluster.version
    end

    hop_wait unless node_to_upgrade

    bud Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id, "nodepool_id" => kubernetes_nodepool.id, "subject_id" => kubernetes_nodepool.cluster.id}
    hop_wait_upgrade
  end

  label def wait_upgrade
    reap
    hop_upgrade if leaf?
    donate
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
