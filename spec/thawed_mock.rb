# frozen_string_literal: true

module ThawedMock
  OBJECTS = {}

  def self.allow_mocking(obj, *methods)
    mod, mock = OBJECTS[obj]
    unless mod
      mod = Module.new
      mock = Object.new

      obj.singleton_class.prepend(mod)
      OBJECTS[obj] = [mod, mock].freeze
    end

    methods.each do |method|
      original_method = obj.method(method)

      mock.define_singleton_method(method) do |*a, **kw, &b|
        original_method.call(*a, **kw, &b)
      end

      mod.define_method(method) do |*a, **kw, &b|
        mock.send(method, *a, **kw, &b)
      end
    end
  end

  module ExpectOverride
    [:allow, :expect].each do |method|
      define_method(method) do |obj = nil, &block|
        return super(&block) if obj.nil? && block

        _, mock = OBJECTS[obj]
        super(mock || obj, &block)
      end
    end
  end
  RSpec::Core::ExampleGroup.prepend(ExpectOverride)

  # Ruby Core Classes
  allow_mocking(File, :exist?, :open, :rename, :write)
  allow_mocking(Kernel, :exit, :exit!, :URI)
  allow_mocking(Thread, :new, :list)
  allow_mocking(Time, :now)

  # Database
  allow_mocking(DB, :[])

  # Models
  allow_mocking(Account, :[])
  allow_mocking(Address, :where)
  allow_mocking(ApiKey, :generate_uuid, :random_key)
  allow_mocking(ArchivedRecord, :create)
  allow_mocking(AssignedVmAddress, :create)
  allow_mocking(AwsInstance, :create_with_id)
  allow_mocking(BillingRecord, :create)
  allow_mocking(BootImage, :where)
  allow_mocking(DnsRecord, :[], :create)
  allow_mocking(DnsZone, :[], :where)
  allow_mocking(Firewall, :generate_uuid)
  allow_mocking(FirewallRule, :create, :generate_uuid)
  allow_mocking(Github, :app_client, :failed_deliveries, :installation_client, :oauth_client, :redeliver_failed_deliveries)
  allow_mocking(GithubRunner, :[], :any?, :first, :join)
  allow_mocking(HostProvider, :create)
  allow_mocking(IpsecTunnel, :[], :create)
  allow_mocking(KubernetesCluster, :[], :kubeconfig, :generate_ubid)
  allow_mocking(KubernetesNodepool, :generate_uuid)
  allow_mocking(LoadBalancer, :[], :generate_uuid)
  allow_mocking(MinioCluster, :[])
  allow_mocking(Nic, :[], :create_with_id, :generate_ubid)
  allow_mocking(OidcProvider, :generate_uuid)
  allow_mocking(Page, :from_tag_parts)
  allow_mocking(PgAwsAmi, :where)
  allow_mocking(PrivateSubnet, :[], :random_subnet, :generate_ubid)
  allow_mocking(PrivateSubnetFirewall, :where)
  allow_mocking(PostgresFirewallRule, :generate_uuid)
  allow_mocking(PostgresLsnMonitor, :new)
  allow_mocking(PostgresMetricDestination, :generate_uuid)
  allow_mocking(PostgresResource, :[], :generate_uuid)
  allow_mocking(PostgresServer, :[], :create, :create_with_id, :victoria_metrics_client)
  allow_mocking(PostgresTimeline, :[], :earliest_restore_time)
  allow_mocking(Project, :[], :order_by)
  allow_mocking(Semaphore, :where, :create, :incr)
  allow_mocking(SshPublicKey, :generate_uuid)
  allow_mocking(Sshable, :create_with_id, :repl?)
  allow_mocking(StorageKeyEncryptionKey, :create)
  allow_mocking(Strand, :create, :create_with_id)
  allow_mocking(UsageAlert, :where)
  allow_mocking(VmHost, :[], :where)
  allow_mocking(Vm, :[], :where, :generate_ubid)
  allow_mocking(VmPool, :[], :where)
  allow_mocking(VmHostCpu, :create)
  allow_mocking(VmHostSlice, :[], :dataset)
  allow_mocking(VmStorageVolume, :create)
  allow_mocking(VictoriaMetricsServer, :[])
  allow_mocking(VictoriaMetricsResource, :[], :first, :client_for_project)

  # Progs
  allow_mocking(Prog::Base, :current_prog)
  allow_mocking(Prog::Ai::InferenceEndpointNexus, :assemble, :model_for_id)
  allow_mocking(Prog::Ai::InferenceEndpointReplicaNexus, :assemble)
  allow_mocking(Prog::Ai::InferenceRouterReplicaNexus, :assemble)
  allow_mocking(Prog::DnsZone::SetupDnsServerVm, :vms_in_sync?)
  allow_mocking(Prog::Github::DestroyGithubInstallation, :assemble)
  allow_mocking(Prog::Minio::MinioClusterNexus, :assemble)
  allow_mocking(Prog::PageNexus, :assemble)
  allow_mocking(Prog::Postgres::PostgresResourceNexus, :assemble)
  allow_mocking(Prog::Postgres::PostgresServerNexus, :assemble)
  allow_mocking(Prog::Postgres::PostgresTimelineNexus, :assemble)
  allow_mocking(Prog::Vm::GithubRunner, :assemble)
  allow_mocking(Prog::Vm::HostNexus, :assemble)
  allow_mocking(Prog::Vm::Nexus, :assemble, :assemble_with_sshable)
  allow_mocking(Prog::Vm::VmPool, :assemble)
  allow_mocking(Prog::Vnet::NicNexus, :assemble, :gen_mac, :rand)
  allow_mocking(Prog::Vnet::SubnetNexus, :assemble, :random_private_ipv4, :random_private_ipv6)

  # Other Classes
  allow_mocking(BillingRate, :from_resource_properties)
  allow_mocking(Clog, :emit)
  allow_mocking(CloudflareClient, :new)
  allow_mocking(Clover, :call, :authorized_project)
  allow_mocking(EmailRenderer, :sendmail)
  allow_mocking(Hosting::Apis, :pull_data_center, :pull_ips, :reimage_server, :hardware_reset_server, :set_server_name)
  allow_mocking(InvoiceGenerator, :new)
  allow_mocking(Minio::Client, :new)
  allow_mocking(Minio::Crypto, :new)
  allow_mocking(RunpodClient, :new)
  allow_mocking(Scheduling::Allocator, :allocate)
  allow_mocking(Scheduling::Allocator::Allocation, :best_allocation, :candidate_hosts, :new, :random_score, :update_vm)
  allow_mocking(Scheduling::Allocator::StorageAllocation, :new)
  allow_mocking(Scheduling::Allocator::VmHostCpuAllocation, :new)
  allow_mocking(Scheduling::Allocator::VmHostAllocation, :new)
  allow_mocking(Serializers::Vm, :serialize_internal)
  allow_mocking(SshKey, :generate)
  allow_mocking(ThreadPrinter, :puts, :run)
  allow_mocking(Util, :create_certificate, :create_root_certificate, :rootish_ssh, :send_email)
  allow_mocking(UBID, :class_match?)
  allow_mocking(VictoriaMetrics::Client, :new)
end
