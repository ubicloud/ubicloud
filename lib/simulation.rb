# frozen_string_literal: true

# Database-only infrastructure for simulating GitHub runner provisioning.
# With Config.simulation_mode, VM hosts and VMs exist only as records: the
# allocator places VMs as usual, but nothing is ever run on a host.
module Simulation
  CUSTOMER_PROJECT_NAME = "simulated-customer"

  def self.customer_project
    Project.first(name: CUSTOMER_PROJECT_NAME) || fail("Simulation is not seeded, run bin/simulation-seed first")
  end

  # The simulator may send webhooks for any installation id, so register
  # unknown installations under the simulated customer on first sight.
  def self.find_or_register_installation(installation_id, name)
    if (installation = GithubInstallation.with_github_installation_id(installation_id))
      return installation
    end

    GithubInstallation.dataset.insert_conflict(target: :installation_id).insert(
      id: GithubInstallation.generate_uuid,
      installation_id:,
      name: name || "simulated-#{installation_id}",
      type: "Organization",
      project_id: customer_project.id,
    )
    GithubInstallation.with_github_installation_id(installation_id)
  end

  RUNTIME_PROGS = %w[Github::GithubRunnerNexus Github::GithubRepositoryNexus Vm::Metal::Nexus Vnet::Metal::SubnetNexus
    Vnet::Metal::NicNexus Vm::VmHostSliceNexus PageNexus].freeze

  # Deletes every runner, VM, and everything created for them, and resets
  # the scheduler metrics. Stop web and respirate first, so that nothing is
  # created or progressed meanwhile. Hosts are kept, emptied, unless
  # include_hosts is set.
  def self.reset(include_hosts: false)
    fail "Simulation mode is not enabled" unless Config.simulation_mode

    DB.transaction do
      DB[:semaphore].where(strand_id: DB[:strand].where(prog: RUNTIME_PROGS).select(:id)).delete
      DB[:strand].where(prog: RUNTIME_PROGS).delete
      %i[github_runner github_cache_entry github_repository github_installation_private_subnet github_custom_label
        github_installation assigned_vm_address vm_storage_volume firewalls_vms vm_init_script ipsec_tunnel nic].each { DB[it].delete }
      vm_ids = DB[:vm].select_map(:id)
      DB[:vm].delete
      DB[:sshable].where(id: vm_ids).delete
      DB[:vm_host_cpu].update(vm_host_slice_id: nil)
      %i[vm_host_slice firewall_rule firewalls_private_subnets firewall private_subnet page_root_resource page_snooze page
        scheduler_metric_counter].each { DB[it].delete }

      if include_hosts
        host_ids = DB[:vm_host].select_map(:id)
        cidrs = DB[:address].where(routed_to_host_id: host_ids).select(:cidr)
        DB[:ipv4_address].where(cidr: cidrs).delete
        %i[vm_host_cpu storage_device boot_image vhost_block_backend assigned_host_address].each { DB[it].where((it == :assigned_host_address) ? :host_id : :vm_host_id => host_ids).delete }
        DB[:address].where(routed_to_host_id: host_ids).delete
        DB[:vm_host].delete
        DB[:sshable].where(id: host_ids).delete
      else
        VmHost.each { it.update(used_cores: it.io_cpu_count * it.total_cores / it.total_cpus, used_hugepages_1g: 0) }
        DB[:storage_device].update(available_storage_gib: :total_storage_gib)
      end
    end
  end

  def self.seed(host_count:, family: "standard", arch: "x64", location_id: Location::GITHUB_RUNNERS_ID,
    total_cores: 48, threads_per_core: 2, total_hugepages_1g: 360, storage_devices: 2, storage_gib_per_device: 3500,
    boot_images: Github.runner_labels.values.map { it["boot_image"] }.uniq, os_version: "ubuntu-24.04")
    fail "Simulation mode is not enabled" unless Config.simulation_mode
    fail "GITHUB_RUNNER_SERVICE_PROJECT_ID is not set" unless (service_project_id = Config.github_runner_service_project_id)

    DB.transaction do
      Project[service_project_id] || Project.create_with_id(service_project_id, name: "github-runner-service")

      unless Project.first(name: CUSTOMER_PROJECT_NAME)
        billing_info = BillingInfo.create(stripe_id: "simulated-#{SecureRandom.hex(8)}")
        project = Project.create(name: CUSTOMER_PROJECT_NAME, billing_info_id: billing_info.id, reputation: "verified")
        ["GithubRunnerVCpu", "GithubRunnerVCpuArm"].each do |resource_type|
          ProjectQuota.create(project_id: project.id, quota_id: ProjectQuota.default_quotas[resource_type]["id"], value: 1_000_000)
        end
      end

      host_offset = VmHost.count
      total_cpus = total_cores * threads_per_core
      Array.new(host_count) do |i|
        n = host_offset + i
        id = VmHost.generate_uuid
        Sshable.create_with_id(id, host: "simulated-host-#{n}")
        vm_host = VmHost.create_with_id(id,
          location_id:, family:, arch:, os_version:,
          allocation_state: "accepting",
          accepts_slices: true,
          data_center: "SIM-DC#{n % 4}",
          net6: "fd00:#{(n / 65536).to_s(16)}:#{(n % 65536).to_s(16)}::/64",
          total_sockets: 1, total_dies: 1, total_cores:, total_cpus:,
          total_mem_gib: total_hugepages_1g + 24,
          total_hugepages_1g:)

        vm_host.update(used_cores: vm_host.io_cpu_count * total_cores / total_cpus)
        DB[:vm_host_cpu].import([:vm_host_id, :cpu_number, :io, :numa_node],
          Array.new(total_cpus) { [id, it, it < vm_host.io_cpu_count, 0] })

        # Every host gets its own /24 of CGNAT space, so a host fits 256 VMs.
        cidr = "100.#{64 + n / 256}.#{n % 256}.0/24"
        Address.create(cidr:, routed_to_host_id: id).populate_ipv4_addresses

        storage_devices.times do |d|
          StorageDevice.create(vm_host_id: id, name: (d == 0) ? "DEFAULT" : "nvme#{d}n1",
            total_storage_gib: storage_gib_per_device, available_storage_gib: storage_gib_per_device)
        end
        VhostBlockBackend.create(vm_host_id: id, version: Config.vhost_block_backend_version, allocation_weight: 100)
        boot_images.each do |name|
          BootImage.create(vm_host_id: id, name:, version: "simulated", size_gib: 20, activated_at: Time.now)
        end

        vm_host
      end
    end
  end
end
