# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, project_id:, location_id:, version: "v1.32", private_subnet_id: nil, cp_node_count: 3, target_node_size: "standard-2", target_node_storage_size_gib: nil)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      unless Option.kubernetes_versions.include?(version)
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
    incr_install_metrics_server
    incr_sync_worker_mesh
    hop_create_load_balancers
  end

  label def create_load_balancers
    custom_hostname_dns_zone_id = DnsZone[name: Config.kubernetes_service_hostname]&.id
    custom_apiserver_hostname_prefix = if custom_hostname_dns_zone_id
      "#{kubernetes_cluster.name}-apiserver-#{kubernetes_cluster.ubid.to_s[-5...]}"
    end

    custom_services_hostname_prefix = if custom_hostname_dns_zone_id
      "#{kubernetes_cluster.name}-services-#{kubernetes_cluster.ubid.to_s[-5...]}"
    end

    api_server_lb = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: kubernetes_cluster.apiserver_load_balancer_name,
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix: custom_apiserver_hostname_prefix
    ).subject

    services_lb = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: kubernetes_cluster.services_load_balancer_name,
      algorithm: "hash_based",
      # TODO: change the api to support LBs without ports
      # The next two fields will be later modified by the sync_kubernetes_services label
      # These are just set for passing the creation validations
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix: custom_services_hostname_prefix,
      stack: LoadBalancer::Stack::IPV4 # TODO: Can we change this to DUAL?
    ).subject

    kubernetes_cluster.update(api_server_lb_id: api_server_lb.id, services_lb_id: services_lb.id)

    services_lb.dns_zone&.insert_record(record_name: "*.#{services_lb.hostname}.", type: "CNAME", ttl: 3600, data: "#{services_lb.hostname}.")

    hop_bootstrap_control_plane_vms
  end

  label def bootstrap_control_plane_vms
    nap 5 unless kubernetes_cluster.endpoint

    # In 1-node control plane setup, we will wait until it's over
    # In 3-node control plane setup, we start the bootstrapping after
    # the first CP bootstrap
    ready_to_bootstrap_workers =
      kubernetes_cluster.cp_vms.count >= kubernetes_cluster.cp_node_count ||
      (kubernetes_cluster.cp_node_count == 3 && kubernetes_cluster.cp_vms.count == 1)
    kubernetes_cluster.nodepools.each(&:incr_start_bootstrapping) if ready_to_bootstrap_workers

    hop_wait_nodes if kubernetes_cluster.cp_vms.count >= kubernetes_cluster.cp_node_count

    bud Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id}

    hop_wait_control_plane_node
  end

  label def wait_control_plane_node
    reap(:bootstrap_control_plane_vms)
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

    when_upgrade_set? do
      hop_upgrade
    end

    when_install_metrics_server_set? do
      hop_install_metrics_server
    end

    when_sync_worker_mesh_set? do
      hop_sync_worker_mesh
    end
    nap 6 * 60 * 60
  end

  label def sync_kubernetes_services
    decr_sync_kubernetes_services
    # TODO: timeout or other logic to avoid apoptosis should be added
    kubernetes_cluster.client.sync_kubernetes_services
    hop_wait
  end

  label def upgrade
    decr_upgrade

    node_to_upgrade = kubernetes_cluster.cp_vms.find do |vm|
      vm_version = kubernetes_cluster.client(session: vm.sshable.connect).version
      vm_minor_version = vm_version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i
      cluster_minor_version = kubernetes_cluster.version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i

      next false unless vm_minor_version && cluster_minor_version
      vm_minor_version == cluster_minor_version - 1
    end

    hop_wait unless node_to_upgrade

    bud Prog::Kubernetes::UpgradeKubernetesNode, {"old_vm_id" => node_to_upgrade.id}
    hop_wait_upgrade
  end

  label def wait_upgrade
    reap(:upgrade)
  end

  label def install_metrics_server
    decr_install_metrics_server

    vm = kubernetes_cluster.cp_vms.first
    case vm.sshable.d_check("install_metrics_server")
    when "Succeeded"
      Clog.emit("Metrics server is installed")
      hop_wait
    when "NotStarted"
      vm.sshable.d_run("install_metrics_server", "kubernetes/bin/install-metrics-server")
      nap 30
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("METRICS SERVER INSTALLATION FAILED")
      nap 65536
    end

    nap 65536
  end

  label def sync_worker_mesh
    decr_sync_worker_mesh

    key_pairs = kubernetes_cluster.worker_vms.map do |vm|
      {vm: vm, ssh_key: SshKey.generate}
    end

    public_keys = key_pairs.map { |kp| kp[:ssh_key].public_key }
    key_pairs.each do |kp|
      vm = kp[:vm]
      vm.sshable.cmd("tee ~/.ssh/id_ed25519 > /dev/null && chmod 0600 ~/.ssh/id_ed25519", stdin: kp[:ssh_key].private_key)
      all_keys_str = ([vm.sshable.keys.first.public_key] + public_keys).join("\n")
      vm.sshable.cmd("tee ~/.ssh/authorized_keys > /dev/null && chmod 0600 ~/.ssh/authorized_keys", stdin: all_keys_str)
    end

    hop_wait
  end

  label def destroy
    reap do
      decr_destroy

      if (services_lb = kubernetes_cluster.services_lb)
        services_lb.dns_zone.delete_record(record_name: "*.#{services_lb.hostname}.")
        services_lb.incr_destroy
      end

      kubernetes_cluster.api_server_lb&.incr_destroy
      kubernetes_cluster.cp_vms.each(&:incr_destroy)
      kubernetes_cluster.remove_all_cp_vms
      kubernetes_cluster.nodepools.each { it.incr_destroy }
      kubernetes_cluster.private_subnet.incr_destroy
      nap 5 unless kubernetes_cluster.nodepools.empty?
      kubernetes_cluster.destroy
      pop "kubernetes cluster is deleted"
    end
  end
end
