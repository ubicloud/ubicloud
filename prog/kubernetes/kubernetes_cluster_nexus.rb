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

      subnet = if private_subnet_id
        project.private_subnets_dataset.first(id: private_subnet_id) || fail("Given subnet is not available in the given project")
      else
        subnet_name = name + "-k8s-subnet"
        ps = project.private_subnets_dataset.first(:location_id => location_id, Sequel[:private_subnet][:name] => subnet_name)
        ps || Prog::Vnet::SubnetNexus.assemble(
          project_id,
          name: subnet_name,
          location_id:,
          ipv4_range: Prog::Vnet::SubnetNexus.random_private_ipv4(Location[location_id], project, 18).to_s
        ).subject
      end

      # TODO: Validate location
      # TODO: Move resources (vms, subnet, LB, etc.) into our own project
      # TODO: Validate node count

      kc = KubernetesCluster.create_with_id(name:, version:, cp_node_count:, location_id:, target_node_size:, target_node_storage_size_gib:, project_id: project.id, private_subnet_id: subnet.id)

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
    custom_hostname_dns_zone_id = DnsZone[name: Config.kubernetes_service_hostname]&.id
    custom_hostname_prefix = if custom_hostname_dns_zone_id
      "#{kubernetes_cluster.name}-apiserver-#{kubernetes_cluster.ubid.to_s[-5...]}"
    end
    load_balancer_st = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: "#{kubernetes_cluster.name}-apiserver",
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix:,
      stack: LoadBalancer::Stack::IPV4
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
    kubernetes_cluster.nodepools.each { _1.incr_destroy }
    nap 5 unless kubernetes_cluster.nodepools.empty?
    kubernetes_cluster.destroy
    pop "kubernetes cluster is deleted"
  end
end
