# frozen_string_literal: true

require_relative "../spec_helper"

module AdminModelSpecHelper
  if ENV["UNUSED_ASSOCIATIONS"]
    # Skip admin model tests when looking for unused associations, as the admin
    # model tests will access all defined associations.
    def self.included(mod)
      mod.define_singleton_method(:before) { |*| }
      mod.define_singleton_method(:it) { |*| }
    end
  else
    def create_access_control_entry
      project = Project.create(name: "test-project")
      subject_tag = SubjectTag.create(project_id: project.id, name: "Admin")
      AccessControlEntry.create(project_id: project.id, subject_id: subject_tag.id)
    end

    def create_action_tag
      project = Project.create(name: "test-project")
      ActionTag.create(project_id: project.id, name: "test-action")
    end

    def create_action_type
      ActionType.first
    end

    def create_address
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      Address.create(cidr: "10.0.0.0/24", routed_to_host_id: host.id)
    end

    def create_api_key
      account = create_account
      project = account.projects.first
      ApiKey.create(owner_id: account.id, owner_table: "accounts", key: "test-key-value", used_for: "api", project_id: project.id)
    end

    def create_assigned_host_address
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      addr = Address.create(cidr: "10.0.0.0/24", routed_to_host_id: host.id)
      AssignedHostAddress.create(ip: "10.0.0.1/32", address_id: addr.id, host_id: host.id)
    end

    def create_assigned_vm_address
      project = Project.create(name: "test-project")
      vm = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "test-vm").subject
      host = vm.vm_host || Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      addr = Address.create(cidr: "10.0.0.0/24", routed_to_host_id: host.id)
      AssignedVmAddress.create(ip: "10.0.0.1/32", address_id: addr.id, dst_vm_id: vm.id)
    end

    def create_aws_instance
      AwsInstance.create(instance_id: "i-1234567890")
    end

    def create_aws_subnet
      ps_aws_resource = create_private_subnet_aws_resource
      location_aws_az = create_location_aws_az
      AwsSubnet.create(private_subnet_aws_resource_id: ps_aws_resource.id, location_aws_az_id: location_aws_az.id, ipv4_cidr: "10.0.0.0/24")
    end

    def create_billing_info
      BillingInfo.create(stripe_id: "cus_test123")
    end

    def create_billing_record
      project = Project.create(name: "test-project")
      vm = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "test-vm").subject
      BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        span: Sequel::Postgres::PGRange.new(Time.now - 3600, nil),
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus
      )
    end

    def create_boot_image
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      BootImage.create(name: "ubuntu-jammy", version: "20240101", vm_host_id: host.id, size_gib: 10)
    end

    def create_cert
      project = Project.create(name: "test-project")
      zone = DnsZone.create(project_id: project.id, name: "test.com")
      Cert.create(hostname: "test.example.com", dns_zone_id: zone.id, cert: "cert-data")
    end

    def create_connected_subnet
      project = Project.create(name: "test-project")
      ps1 = PrivateSubnet.create(name: "test-ps1", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      ps2 = PrivateSubnet.create(name: "test-ps2", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.1.0/26", net6: "fdfb::/64")
      # Ensure subnet_id_1 < subnet_id_2 for the check constraint
      subnet_ids = [ps1.id, ps2.id].sort
      ConnectedSubnet.create(subnet_id_1: subnet_ids[0], subnet_id_2: subnet_ids[1])
    end

    def create_discount_code
      DiscountCode.create(code: "TEST123", credit_amount: 10, expires_at: Time.now + 86400)
    end

    def create_dns_record
      project = Project.create(name: "test-project")
      zone = DnsZone.create(project_id: project.id, name: "test.com")
      DnsRecord.create(dns_zone_id: zone.id, name: "www", type: "A", ttl: 300, data: "1.2.3.4")
    end

    def create_dns_server
      DnsServer.create(name: "test-dns-server")
    end

    def create_dns_zone
      project = Project.create(name: "test-project")
      DnsZone.create(project_id: project.id, name: "test.com")
    end

    def create_firewall
      project = Project.create(name: "test-project")
      Firewall.create(name: "test-firewall", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
    end

    def create_firewall_rule
      project = Project.create(name: "test-project")
      firewall = Firewall.create(name: "test-firewall", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80..80))
    end

    def create_github_cache_entry
      installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
      repo = GithubRepository.create(installation_id: installation.id, name: "test-repo")
      runner = GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud")
      GithubCacheEntry.create(repository_id: repo.id, key: "test-key", version: "v1", scope: "test", created_by: runner.id)
    end

    def create_github_custom_label
      installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
      GithubCustomLabel.create(installation_id: installation.id, name: "custom-label", alias_for: "ubicloud-standard-2")
    end

    def create_github_installation
      GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
    end

    def create_github_repository
      installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
      GithubRepository.create(installation_id: installation.id, name: "test-repo")
    end

    def create_github_runner
      installation = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User")
      GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label: "ubicloud")
    end

    def create_globally_blocked_dnsname
      GloballyBlockedDnsname.create(dns_name: "blocked.example.com")
    end

    def create_gpu_partition
      host = Prog::Vm::HostNexus.assemble("1.2.3.4", family: "gpu-standard").subject
      GpuPartition.create(vm_host_id: host.id, partition_id: 0, gpu_count: 1)
    end

    def create_inference_endpoint
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      lb = LoadBalancer.create(name: "test-lb", project_id: project.id, private_subnet_id: ps.id, health_check_endpoint: "/health")
      InferenceEndpoint.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-endpoint",
        model_name: "test-model",
        private_subnet_id: ps.id,
        load_balancer_id: lb.id,
        boot_image: "ai-ubuntu-jammy",
        vm_size: "gpu-standard-2",
        storage_volumes: [{size_gib: 100}].to_json,
        engine: "vllm",
        engine_params: "{}",
        replica_count: 1
      )
    end

    def create_inference_endpoint_replica
      endpoint = create_inference_endpoint
      vm = Prog::Vm::Nexus.assemble_with_sshable(endpoint.project_id, name: "replica-vm", private_subnet_id: endpoint.private_subnet_id).subject
      InferenceEndpointReplica.create(inference_endpoint_id: endpoint.id, vm_id: vm.id)
    end

    def create_inference_router
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      lb = LoadBalancer.create(name: "test-lb", project_id: project.id, private_subnet_id: ps.id, health_check_endpoint: "/health")
      InferenceRouter.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-router",
        private_subnet_id: ps.id,
        load_balancer_id: lb.id,
        vm_size: "standard-2",
        replica_count: 1
      )
    end

    def create_inference_router_model
      InferenceRouterModel.create(
        model_name: "test/model-#{SecureRandom.hex(4)}",
        prompt_billing_resource: "prompt",
        completion_billing_resource: "completion",
        project_inflight_limit: 10,
        project_prompt_tps_limit: 100,
        project_completion_tps_limit: 100
      )
    end

    def create_inference_router_replica
      router = create_inference_router
      vm = Prog::Vm::Nexus.assemble_with_sshable(router.project_id, name: "router-replica-vm", private_subnet_id: router.private_subnet_id).subject
      InferenceRouterReplica.create(inference_router_id: router.id, vm_id: vm.id)
    end

    def create_inference_router_target
      router = create_inference_router
      router_model = create_inference_router_model
      InferenceRouterTarget.create(
        name: "test-inference-router",
        host: "127.0.0.1",
        api_key: "a",
        inflight_limit: 1,
        priority: 1,
        inference_router_id: router.id,
        inference_router_model_id: router_model.id
      )
    end

    def create_invoice
      project = Project.create(name: "test-project")
      Invoice.create(
        project_id: project.id,
        invoice_number: "test-invoice-#{SecureRandom.hex(4)}",
        content: {billing_info: {country: "US"}, cost: 10, subtotal: 10},
        begin_time: Time.now - 86400,
        end_time: Time.now
      )
    end

    def create_ipsec_tunnel
      project = Project.create(name: "test-project")
      ps1 = PrivateSubnet.create(name: "test-ps1", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      ps2 = PrivateSubnet.create(name: "test-ps2", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.1.0/26", net6: "fdfb::/64")
      vm1 = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "vm1", private_subnet_id: ps1.id).subject
      vm2 = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "vm2", private_subnet_id: ps2.id).subject
      nic1 = Nic.create(private_subnet_id: ps1.id, vm_id: vm1.id, name: "default", private_ipv4: "10.0.0.2", private_ipv6: "fdfa::2", mac: "00:00:00:00:00:02", state: "active")
      nic2 = Nic.create(private_subnet_id: ps2.id, vm_id: vm2.id, name: "default", private_ipv4: "10.0.1.2", private_ipv6: "fdfb::2", mac: "00:00:00:00:00:03", state: "active")
      IpsecTunnel.create(src_nic_id: nic1.id, dst_nic_id: nic2.id)
    end

    def create_kubernetes_cluster
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      KubernetesCluster.create(
        project_id: project.id,
        name: "test-cluster",
        private_subnet_id: ps.id,
        location_id: Location::HETZNER_FSN1_ID,
        cp_node_count: 3,
        version: Option.kubernetes_versions.first,
        target_node_size: "standard-2"
      )
    end

    def create_kubernetes_etcd_backup
      cluster = create_kubernetes_cluster
      KubernetesEtcdBackup.create(
        access_key: "a",
        secret_key: "b",
        location_id: Location::HETZNER_FSN1_ID,
        kubernetes_cluster_id: cluster.id
      )
    end

    def create_kubernetes_node
      cluster = create_kubernetes_cluster
      vm = Prog::Vm::Nexus.assemble_with_sshable(cluster.project_id, name: "k8s-node-vm", private_subnet_id: cluster.private_subnet_id).subject
      KubernetesNode.create(kubernetes_cluster_id: cluster.id, vm_id: vm.id)
    end

    def create_kubernetes_nodepool
      cluster = create_kubernetes_cluster
      KubernetesNodepool.create(kubernetes_cluster_id: cluster.id, name: "test-pool", target_node_size: "standard-2", node_count: 1)
    end

    def create_load_balancer
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      LoadBalancer.create(name: "test-lb", project_id: project.id, private_subnet_id: ps.id, health_check_endpoint: "/health")
    end

    def create_load_balancer_port
      lb = create_load_balancer
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8080)
    end

    def create_load_balancer_vm
      lb = create_load_balancer
      vm = Prog::Vm::Nexus.assemble_with_sshable(lb.project_id, name: "lb-vm", private_subnet_id: lb.private_subnet_id).subject
      LoadBalancerVm.create(load_balancer_id: lb.id, vm_id: vm.id)
    end

    def create_load_balancer_vm_port
      lbvm = create_load_balancer_vm
      lb_port = LoadBalancerPort.create(load_balancer_id: lbvm.load_balancer_id, src_port: 80, dst_port: 8080)
      LoadBalancerVmPort.create(load_balancer_vm_id: lbvm.id, load_balancer_port_id: lb_port.id, stack: "ipv4")
    end

    def create_location
      Location.create(name: "test-loc", display_name: "Test Location", ui_name: "Test", visible: true, provider: "hetzner")
    end

    def create_location_aws_az
      location = Location.create(name: "us-east-1", display_name: "AWS US East 1", ui_name: "AWS US East", visible: true, provider: "aws", project_id: nil)
      LocationAwsAz.create(location_id: location.id, az: "us-east-1a", zone_id: "use1-az1")
    end

    def create_location_credential
      location = Location.create(name: "test-loc-cred", display_name: "Test Location", ui_name: "Test", visible: true, provider: "aws")
      LocationCredential.create(access_key: "test-key", secret_key: "test-secret") { it.id = location.id }
    end

    def create_minio_cluster
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      MinioCluster.create(
        name: "test-cluster",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        private_subnet_id: ps.id,
        admin_user: "admin",
        admin_password: "test-password"
      )
    end

    def create_minio_pool
      cluster = create_minio_cluster
      MinioPool.create(cluster_id: cluster.id, server_count: 1, drive_count: 1, storage_size_gib: 100, vm_size: "standard-2", start_index: 0)
    end

    def create_minio_server
      pool = create_minio_pool
      vm = Prog::Vm::Nexus.assemble_with_sshable(pool.cluster.project_id, name: "minio-vm", private_subnet_id: pool.cluster.private_subnet_id).subject
      MinioServer.create(minio_pool_id: pool.id, vm_id: vm.id, index: 0)
    end

    def create_nic
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      vm = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "test-vm", private_subnet_id: ps.id).subject
      Nic.create(private_subnet_id: ps.id, vm_id: vm.id, name: "default", private_ipv4: "10.0.0.2", private_ipv6: "fdfa::2", mac: "00:00:00:00:00:02", state: "active")
    end

    def create_nic_aws_resource
      nic = create_nic
      NicAwsResource.create_with_id(nic, network_interface_id: "eni-12345")
    end

    def create_object_tag
      project = Project.create(name: "test-project")
      ObjectTag.create(project_id: project.id, name: "test-object-tag")
    end

    def create_oidc_provider
      OidcProvider.create(
        display_name: "Test Provider",
        url: "https://test.example.com",
        client_id: "test-client-id",
        client_secret: "test-client-secret",
        authorization_endpoint: "/oauth/authorize",
        token_endpoint: "/oauth/token",
        userinfo_endpoint: "/oauth/userinfo",
        jwks_uri: "https://test.example.com/.well-known/jwks.json"
      )
    end

    def create_page
      Page.create(summary: "Test page", tag: "test-tag", details: {})
    end

    def create_payment_method
      billing_info = BillingInfo.create(stripe_id: "cus_test123")
      PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "pm_test456")
    end

    def create_pci_device
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      PciDevice.create(vm_host_id: host.id, slot: "0000:01:00.0", device_class: "0x0302", vendor: "0x10de", device: "0x2230", iommu_group: 1, numa_node: 0)
    end

    def create_pg_aws_ami
      PgAwsAmi.create(aws_ami_id: "ami-#{SecureRandom.hex(4)}", aws_location_name: "us-east-#{SecureRandom.hex(2)}", pg_version: "16", arch: "x64")
    end

    def create_postgres_metric_destination
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      vm = Prog::Vm::Nexus.assemble_with_sshable(project.id, name: "vm-metrics", private_subnet_id: ps.id).subject
      vmr = VictoriaMetricsResource.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        private_subnet_id: ps.id,
        name: "test-vmr",
        admin_user: "admin",
        admin_password: "test-password",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100
      )
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: vm.id)
      pg = PostgresResource.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-pg",
        superuser_password: "test-pass",
        ha_type: "none",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        target_version: "16"
      )
      PostgresMetricDestination.create_with_id(pg, url: "https://metrics.example.com", username: "test", password: "test-pass", postgres_resource_id: pg.id)
    end

    def create_postgres_init_script
      pg = create_postgres_resource
      PostgresInitScript.create_with_id(pg, init_script: "#!/bin/bash\necho 'Hello, World!'")
    end

    def create_postgres_resource
      project = Project.create(name: "test-project")
      PostgresResource.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-pg",
        superuser_password: "test-pass",
        ha_type: "none",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        target_version: "16"
      )
    end

    def create_postgres_server
      pg = create_postgres_resource
      timeline = PostgresTimeline.create(location_id: pg.location_id, access_key: "test-key", secret_key: "test-secret")
      vm = Prog::Vm::Nexus.assemble_with_sshable(pg.project_id, name: "pg-vm", location_id: pg.location_id, unix_user: "ubi").subject
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1)
      PostgresServer.create(timeline_id: timeline.id, resource_id: pg.id, vm_id: vm.id, version: "18")
    end

    def create_postgres_timeline
      PostgresTimeline.create(location_id: Location::HETZNER_FSN1_ID, access_key: "test-key", secret_key: "test-secret")
    end

    def create_private_subnet
      project = Project.create(name: "test-project")
      PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
    end

    def create_private_subnet_aws_resource
      ps = create_private_subnet
      PrivateSubnetAwsResource.create_with_id(ps, vpc_id: "vpc-12345")
    end

    def create_project
      Project.create(name: "test-project")
    end

    def create_project_discount_code
      project = Project.create(name: "test-project")
      code = DiscountCode.create(code: "TEST123", credit_amount: 10, expires_at: Time.now + 86400)
      ProjectDiscountCode.create(project_id: project.id, discount_code_id: code.id)
    end

    def create_rhizome_installation
      sshable = create_sshable
      RhizomeInstallation.create_with_id(sshable, folder: "test-folder", commit: "abc123", digest: "def456")
    end

    def create_semaphore
      strand = Strand.create(prog: "Test", label: "test")
      Semaphore.create(strand_id: strand.id, name: "test-semaphore")
    end

    def create_spdk_installation
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      SpdkInstallation.create(vm_host_id: host.id, version: "24.01", allocation_weight: 100)
    end

    def create_ssh_public_key
      project = Project.create(name: "test-project")
      SshPublicKey.create(project_id: project.id, name: "test-key", public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFakeKeyData test@example.com")
    end

    def create_sshable
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      host.sshable
    end

    def create_storage_device
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      StorageDevice.create(vm_host_id: host.id, name: "nvme0n1", total_storage_gib: 1000, available_storage_gib: 1000)
    end

    def create_storage_key_encryption_key
      StorageKeyEncryptionKey.create(algorithm: "aes-256-gcm", key: "a" * 64, init_vector: "b" * 24, auth_data: "test")
    end

    def create_strand
      Strand.create(prog: "Test", label: "test")
    end

    def create_subject_tag
      project = Project.create(name: "test-project")
      SubjectTag.create(project_id: project.id, name: "test-subject-tag")
    end

    def create_usage_alert
      account = create_account
      project = account.projects.first
      UsageAlert.create(project_id: project.id, user_id: account.id, name: "test-alert", limit: 100)
    end

    def create_vhost_block_backend
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      VhostBlockBackend.create(vm_host_id: host.id, version: "24.01", allocation_weight: 100)
    end

    def create_victoria_metrics_resource
      project = Project.create(name: "test-project")
      ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
      VictoriaMetricsResource.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        private_subnet_id: ps.id,
        name: "test-vmr",
        admin_user: "admin",
        admin_password: "test-password",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100
      )
    end

    def create_victoria_metrics_server
      vmr = create_victoria_metrics_resource
      vm = Prog::Vm::Nexus.assemble_with_sshable(vmr.project_id, name: "vm-metrics", private_subnet_id: vmr.private_subnet_id).subject
      VictoriaMetricsServer.create(victoria_metrics_resource_id: vmr.id, vm_id: vm.id)
    end

    def create_vm
      project = Project.create(name: "test-project")
      Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "test-vm").subject
    end

    def create_vm_host
      Prog::Vm::HostNexus.assemble("1.2.3.4").subject
    end

    def create_vm_host_slice
      host = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      VmHostSlice.create(
        vm_host_id: host.id,
        name: "testslice",
        cores: 2,
        total_memory_gib: 4,
        used_memory_gib: 0,
        total_cpu_percent: 200,
        used_cpu_percent: 0,
        family: "standard"
      )
    end

    def create_vm_init_script
      vm = create_vm
      VmInitScript.create_with_id(vm, init_script: "echo 'test'")
    end

    def create_vm_pool
      VmPool.create(
        size: 3,
        vm_size: "standard-2",
        boot_image: "ubuntu-jammy",
        location_id: Location::HETZNER_FSN1_ID,
        storage_size_gib: 86
      )
    end

    def create_vm_storage_volume
      vm = create_vm
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 10, disk_index: 1)
    end
  end
end
