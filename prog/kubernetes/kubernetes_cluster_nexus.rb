# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, project_id:, location_id:, version: "v1.32", private_subnet_id: nil, cp_node_count: 3, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      unless ["v1.32", "v1.31"].include?(version)
        fail "Invalid Kubernetes Version"
      end

      Validation.validate_kubernetes_name(name)
      Validation.validate_kubernetes_cp_node_count(cp_node_count)

      ubid = KubernetesCluster.generate_ubid
      subnet = if private_subnet_id
        PrivateSubnet[id: private_subnet_id, project_id: Config.kubernetes_service_project_id] || fail("Given subnet is not available in the k8s project")
      else
        Prog::Vnet::SubnetNexus.assemble(
          Config.kubernetes_service_project_id,
          name: "#{ubid}-subnet",
          location_id:,
          ipv4_range: Prog::Vnet::SubnetNexus.random_private_ipv4(Location[location_id], project, 18).to_s
        ).subject
      end

      # TODO: Validate location
      # TODO: Validate node count

      KubernetesCluster.create(name:, version:, cp_node_count:, location_id:, target_node_size:, target_node_storage_size_gib:, project_id: project.id, private_subnet_id: subnet.id) { it.id = ubid.to_uuid }

      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { it.id = ubid.to_uuid }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        kubernetes_cluster.active_billing_records.each(&:finalize)
        hop_destroy
      end
    end
  end

  label def start
    register_deadline("wait", 120 * 60)
    hop_create_load_balancer
  end

  label def create_load_balancer
    custom_hostname_dns_zone_id = DnsZone[name: Config.kubernetes_service_hostname]&.id
    custom_hostname_prefix = if custom_hostname_dns_zone_id
      "#{kubernetes_cluster.name}-apiserver-#{kubernetes_cluster.ubid.to_s[-5...]}"
    end
    load_balancer = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: kubernetes_cluster.apiserver_load_balancer_name,
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix:
    ).subject
    kubernetes_cluster.update(api_server_lb_id: load_balancer.id)

    hop_bootstrap_control_plane_vms
  end

  label def bootstrap_control_plane_vms
    nap 5 unless kubernetes_cluster.endpoint

    hop_wait_nodes if kubernetes_cluster.cp_vms.count >= kubernetes_cluster.cp_node_count

    bud Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id}

    hop_wait_control_plane_node
  end

  label def wait_control_plane_node
    reap
    hop_bootstrap_control_plane_vms if leaf?
    donate
  end

  label def wait_nodes
    nap 10 unless kubernetes_cluster.nodepools.all? { it.strand.label == "wait" }
    hop_create_billing_records
  end

  label def create_billing_records
    records =
      kubernetes_cluster.cp_vms.map { {type: "KubernetesControlPlaneVCpu", family: it.family, amount: it.vcpus} } +
      kubernetes_cluster.nodepools.flat_map(&:vms).flat_map {
        [
          {type: "KubernetesWorkerVCpu", family: it.family, amount: it.vcpus},
          {type: "KubernetesWorkerStorage", family: "standard", amount: it.storage_size_gib}
        ]
      }

    records.each do |record|
      BillingRecord.create(
        project_id: kubernetes_cluster.project_id,
        resource_id: kubernetes_cluster.id,
        resource_name: kubernetes_cluster.name,
        billing_rate_id: BillingRate.from_resource_properties(record[:type], record[:family], kubernetes_cluster.location.name)["id"],
        amount: record[:amount]
      )
    end

    hop_wait
  end

  label def wait
    when_sync_kubernetes_services_set? do
      hop_sync_kubernetes_services
    end
    nap 6 * 60 * 60
  end

  label def sync_kubernetes_services
    decr_sync_kubernetes_services
    # TODO: timeout or other logic to avoid apoptosis should be added
    kubernetes_cluster.client.sync_kubernetes_services
    hop_wait
  end

  label def destroy
    reap
    donate unless leaf?
    decr_destroy
    kubernetes_cluster.api_server_lb.incr_destroy
    kubernetes_cluster.cp_vms.each(&:incr_destroy)
    kubernetes_cluster.remove_all_cp_vms
    kubernetes_cluster.nodepools.each { it.incr_destroy }
    kubernetes_cluster.private_subnet.incr_destroy
    nap 5 unless kubernetes_cluster.nodepools.empty?
    kubernetes_cluster.destroy
    pop "kubernetes cluster is deleted"
  end
end
