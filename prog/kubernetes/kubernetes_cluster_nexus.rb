# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, project_id:, location_id:, version: Option.kubernetes_versions.first, private_subnet_id: nil, cp_node_count: 3, target_node_size: "standard-2", target_node_storage_size_gib: nil)
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

      id = ubid.to_uuid
      KubernetesCluster.create_with_id(id, name:, version:, cp_node_count:, location_id:, target_node_size:, target_node_storage_size_gib:, project_id: project.id, private_subnet_id: subnet.id)

      Strand.create_with_id(id, prog: "Kubernetes::KubernetesClusterNexus", label: "start")
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

  def billing_rate_for(type, family)
    BillingRate.from_resource_properties(type, family, kubernetes_cluster.location.name)
  end

  label def start
    register_deadline("wait", 120 * 60)
    incr_install_metrics_server
    incr_sync_worker_mesh
    incr_install_csi if kubernetes_cluster.project.get_ff_install_csi
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

    services_lb = Prog::Vnet::LoadBalancerNexus.assemble_with_multiple_ports(
      kubernetes_cluster.private_subnet_id,
      ports: [],
      name: kubernetes_cluster.services_load_balancer_name,
      algorithm: "hash_based",
      health_check_endpoint: "/",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id:,
      custom_hostname_prefix: custom_services_hostname_prefix
    ).subject

    kubernetes_cluster.update(api_server_lb_id: api_server_lb.id, services_lb_id: services_lb.id)

    services_lb.dns_zone&.insert_record(record_name: "*.#{services_lb.hostname}.", type: "CNAME", ttl: 3600, data: "#{services_lb.hostname}.")

    hop_bootstrap_control_plane_nodes
  end

  label def bootstrap_control_plane_nodes
    nap 5 unless kubernetes_cluster.endpoint

    ready_to_bootstrap_workers = kubernetes_cluster.nodes.count >= 1
    kubernetes_cluster.nodepools.each(&:incr_start_bootstrapping) if ready_to_bootstrap_workers

    hop_wait_nodes if kubernetes_cluster.nodes.count >= kubernetes_cluster.cp_node_count

    bud Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id}

    hop_wait_control_plane_node
  end

  label def wait_control_plane_node
    reap(:bootstrap_control_plane_nodes)
  end

  label def wait_nodes
    nap 10 unless kubernetes_cluster.nodepools.all? { it.strand.label == "wait" }
    hop_wait
  end

  label def update_billing_records
    decr_update_billing_records
    desired_records = kubernetes_cluster.all_nodes.reject(&:retire_set?).flat_map(&:billing_records).tally
    existing_records = kubernetes_cluster.active_billing_records.map do |record|
      {type: record.billing_rate["resource_type"], family: record.billing_rate["resource_family"], amount: record.amount}
    end.tally

    desired_records.each do |record, want|
      have = existing_records[record] || 0
      (want - have).times do
        BillingRecord.create(
          project_id: kubernetes_cluster.project_id,
          resource_id: kubernetes_cluster.id,
          resource_name: kubernetes_cluster.name,
          billing_rate_id: billing_rate_for(record[:type], record[:family])["id"],
          amount: record[:amount]
        )
      end
    end

    existing_records.each do |record, have|
      want = desired_records[record] || 0
      next unless (surplus = have - want) > 0

      br = billing_rate_for(record[:type], record[:family])
      kubernetes_cluster.active_billing_records_dataset.where(billing_rate_id: br["id"], amount: record[:amount]).order_by(Sequel.desc(Sequel.function(:lower, :span))).limit(surplus).each do |r|
        r.finalize
      end
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

    when_install_csi_set? do
      hop_install_csi
    end

    when_update_billing_records_set? do
      hop_update_billing_records
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

    node_to_upgrade = kubernetes_cluster.nodes.find do |node|
      node_version = kubernetes_cluster.client(session: node.sshable.connect).version
      node_minor_version = node_version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i
      cluster_minor_version = kubernetes_cluster.version.match(/^v\d+\.(\d+)$/)&.captures&.first&.to_i

      next false unless node_minor_version && cluster_minor_version
      node_minor_version == cluster_minor_version - 1
    end

    hop_wait unless node_to_upgrade

    bud Prog::Kubernetes::UpgradeKubernetesNode, {"old_node_id" => node_to_upgrade.id}
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

  label def install_csi
    decr_install_csi
    kubernetes_cluster.client.kubectl("apply -f kubernetes/manifests/ubicsi")
    hop_wait
  end

  label def destroy
    reap do
      decr_destroy

      if (services_lb = kubernetes_cluster.services_lb)
        services_lb.dns_zone&.delete_record(record_name: "*.#{services_lb.hostname}.")
        services_lb.incr_destroy
      end

      kubernetes_cluster.api_server_lb&.incr_destroy
      kubernetes_cluster.cp_vms.each(&:incr_destroy)
      kubernetes_cluster.nodes.each(&:incr_destroy)
      kubernetes_cluster.nodepools.each { it.incr_destroy }
      kubernetes_cluster.private_subnet.incr_destroy
      nap 5 unless kubernetes_cluster.nodepools.empty?
      nap 5 unless kubernetes_cluster.nodes.empty?
      kubernetes_cluster.destroy
      pop "kubernetes cluster is deleted"
    end
  end
end
