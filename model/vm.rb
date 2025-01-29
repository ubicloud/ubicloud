# frozen_string_literal: true

require "jwt"
require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  many_to_one :project
  one_to_many :nics, key: :vm_id, class: :Nic
  many_to_many :private_subnets, join_table: :nic, left_key: :vm_id, right_key: :private_subnet_id
  one_to_one :sshable, key: :id
  one_to_one :assigned_vm_address, key: :dst_vm_id, class: :AssignedVmAddress
  one_to_many :vm_storage_volumes, key: :vm_id, order: Sequel.desc(:boot)
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  one_to_many :pci_devices, key: :vm_id, class: :PciDevice
  one_through_one :load_balancer, left_key: :vm_id, right_key: :load_balancer_id, join_table: :load_balancers_vms
  one_to_one :load_balancers_vms, key: :vm_id, class: :LoadBalancersVms
  many_to_one :vm_host_slice

  plugin :association_dependencies, sshable: :destroy, assigned_vm_address: :destroy, vm_storage_volumes: :destroy, load_balancers_vms: :destroy

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  semaphore :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules, :checkup, :update_spdk_dependency, :waiting_for_capacity, :lb_expiry_started
  semaphore :restart, :stop

  include ObjectTag::Cleanup

  def firewalls
    private_subnets.flat_map(&:firewalls)
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/vm/#{name}"
  end

  def ephemeral_net4
    assigned_vm_address&.ip&.network
  end

  def ip4
    assigned_vm_address&.ip
  end

  def private_ipv4
    nics.first.private_ipv4.network
  end

  def private_ipv6
    nics.first.private_ipv6.nth(2)
  end

  def runtime_token
    JWT.encode({sub: ubid, iat: Time.now.to_i}, Config.clover_runtime_token_secret, "HS256")
  end

  def display_state
    return "deleting" if destroy_set? || strand&.label == "destroy"
    return "restarting" if restart_set? || strand&.label == "restart"
    return "stopped" if stop_set? || strand&.label == "stopped"
    if waiting_for_capacity_set?
      return "no capacity available" if Time.now - created_at > 15 * 60
      return "waiting for capacity"
    end
    super
  end

  # cloud-hypervisor takes topology information in this format:
  #
  # topology=<threads_per_core>:<cores_per_die>:<dies_per_package>:<packages>
  #
  # And the result of multiplication must equal the thread/vcpu count
  # we wish to allocate:
  #
  #     let total = t.threads_per_core * t.cores_per_die * t.dies_per_package * t.packages;
  #     if total != self.cpus.max_vcpus {
  #         return Err(ValidationError::CpuTopologyCount);
  #     }
  CloudHypervisorCpuTopo = Struct.new(:threads_per_core, :cores_per_die, :dies_per_package, :packages) do
    def to_s
      to_a.map(&:to_s).join(":")
    end

    def max_vcpus
      @max_vcpus ||= to_a.reduce(&:*)
    end
  end

  def cloud_hypervisor_cpu_topology
    threads_per_core, r = vm_host.total_cpus.divmod vm_host.total_cores
    fail "BUG" unless r.zero?

    total_dies_per_package, r = vm_host.total_dies.divmod vm_host.total_sockets
    fail "BUG" unless r.zero?

    total_packages = vm_host.total_sockets

    # Computed all-system statistics, now scale it down to meet VM needs.
    proportion = Rational(cores) / vm_host.total_cores
    packages = (total_packages * proportion).ceil
    dies_per_package = (total_dies_per_package * proportion).ceil
    cores_per_die = Rational(cores) / (packages * dies_per_package)
    fail "BUG: need uniform number of cores allocated per die" unless cores_per_die.denominator == 1

    topo = [threads_per_core, cores_per_die, dies_per_package, packages].map { |num|
      # :nocov:
      fail "BUG: non-integer in topology array" unless num.denominator == 1
      # :nocov:
      Integer(num)
    }

    # :nocov:
    unless topo.reduce(&:*) == threads_per_core * cores
      fail "BUG: arithmetic does not result in the correct number of vcpus"
    end
    # :nocov:

    CloudHypervisorCpuTopo.new(*topo)
  end

  # Reverse look-up the vm_size instance that was used to create this VM
  # and use its name as a display name.
  def display_size
    vm_size = Option::VmSizes.find {
      _1.family == family &&
        _1.arch == arch &&
        _1.vcpus == vcpus &&
        (cpu_percent_limit.nil? || _1.cpu_percent_limit == cpu_percent_limit)
    }
    vm_size.name
  end

  # Various names in linux, like interface names, are obliged to be
  # short, so truncate the ubid. This does introduce the spectre of
  # collisions.  When the time comes, we'll have to ensure it doesn't
  # happen on a single host, pushing into the allocation process.
  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def inhost_name
    self.class.ubid_to_name(UBID.from_uuidish(id))
  end

  def storage_size_gib
    vm_storage_volumes.map { _1.size_gib }.sum
  end

  def init_health_monitor_session
    {
      ssh_session: vm_host.sshable.start_fresh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:ssh_session].exec!("systemctl is-active #{inhost_name} #{inhost_name}-dnsmasq").split("\n").all?("active") ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def update_spdk_version(version)
    spdk_installation = vm_host.spdk_installations_dataset[version: version]
    fail "SPDK version #{version} not found on host" unless spdk_installation
    vm_storage_volumes_dataset.update(spdk_installation_id: spdk_installation.id)
    incr_update_spdk_dependency
  end

  def self.redacted_columns
    super + [:public_key]
  end

  def params_json(swap_size_bytes)
    topo = cloud_hypervisor_cpu_topology

    project_public_keys = project.get_ff_vm_public_ssh_keys || []

    # we don't write secrets to params_json, because it
    # shouldn't be stored in the host for security reasons.
    JSON.pretty_generate({
      "vm_name" => name,
      "public_ipv6" => ephemeral_net6.to_s,
      "public_ipv4" => ip4.to_s || "",
      "local_ipv4" => local_vetho_ip.to_s.shellescape || "",
      "dns_ipv4" => nics.first.private_subnet.net4.nth(2).to_s,
      "unix_user" => unix_user,
      "ssh_public_keys" => [public_key] + project_public_keys,
      "nics" => nics.map { |nic| [nic.private_ipv6.to_s, nic.private_ipv4.to_s, nic.ubid_to_tap_name, nic.mac, nic.private_ipv4_gateway] },
      "boot_image" => boot_image,
      "max_vcpus" => topo.max_vcpus,
      "cpu_topology" => topo.to_s,
      "mem_gib" => memory_gib,
      "ndp_needed" => vm_host.ndp_needed,
      "storage_volumes" => storage_volumes,
      "swap_size_bytes" => swap_size_bytes,
      "pci_devices" => pci_devices.map { [_1.slot, _1.iommu_group] },
      "slice_name" => vm_host_slice&.inhost_name || "system.slice",
      "cpu_percent_limit" => cpu_percent_limit || 0,
      "cpu_burst_percent_limit" => cpu_burst_percent_limit || 0
    })
  end

  def storage_volumes
    vm_storage_volumes.map { |s|
      {
        "boot" => s.boot,
        "image" => s.boot_image&.name,
        "image_version" => s.boot_image&.version,
        "size_gib" => s.size_gib,
        "device_id" => s.device_id,
        "disk_index" => s.disk_index,
        "encrypted" => !s.key_encryption_key_1.nil?,
        "spdk_version" => s.spdk_version,
        "use_bdev_ubi" => s.use_bdev_ubi,
        "skip_sync" => s.skip_sync,
        "storage_device" => s.storage_device.name,
        "read_only" => s.size_gib == 0,
        "max_ios_per_sec" => s.max_ios_per_sec,
        "max_read_mbytes_per_sec" => s.max_read_mbytes_per_sec,
        "max_write_mbytes_per_sec" => s.max_write_mbytes_per_sec
      }
    }
  end

  def storage_secrets
    vm_storage_volumes.filter_map { |s|
      if !s.key_encryption_key_1.nil?
        [s.device_id, s.key_encryption_key_1.secret_key_material_hash]
      end
    }.to_h
  end
end

# Table: vm
# Columns:
#  id                      | uuid                     | PRIMARY KEY
#  ephemeral_net6          | cidr                     |
#  vm_host_id              | uuid                     |
#  unix_user               | text                     | NOT NULL
#  public_key              | text                     | NOT NULL
#  display_state           | vm_display_state         | NOT NULL DEFAULT 'creating'::vm_display_state
#  name                    | text                     | NOT NULL
#  location                | text                     | NOT NULL
#  boot_image              | text                     | NOT NULL
#  local_vetho_ip          | text                     |
#  ip4_enabled             | boolean                  | NOT NULL DEFAULT false
#  family                  | text                     | NOT NULL
#  cores                   | integer                  | NOT NULL
#  pool_id                 | uuid                     |
#  created_at              | timestamp with time zone | NOT NULL DEFAULT now()
#  arch                    | arch                     | NOT NULL DEFAULT 'x64'::arch
#  allocated_at            | timestamp with time zone |
#  provisioned_at          | timestamp with time zone |
#  vcpus                   | integer                  | NOT NULL
#  memory_gib              | integer                  | NOT NULL
#  vm_host_slice_id        | uuid                     |
#  project_id              | uuid                     | NOT NULL
#  cpu_percent_limit       | integer                  |
#  cpu_burst_percent_limit | integer                  |
# Indexes:
#  vm_pkey                          | PRIMARY KEY btree (id)
#  vm_ephemeral_net6_key            | UNIQUE btree (ephemeral_net6)
#  vm_project_id_location_name_uidx | UNIQUE btree (project_id, location, name)
# Foreign key constraints:
#  vm_pool_id_fkey          | (pool_id) REFERENCES vm_pool(id)
#  vm_project_id_fkey       | (project_id) REFERENCES project(id)
#  vm_vm_host_id_fkey       | (vm_host_id) REFERENCES vm_host(id)
#  vm_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
# Referenced By:
#  assigned_vm_address        | assigned_vm_address_dst_vm_id_fkey       | (dst_vm_id) REFERENCES vm(id)
#  dns_servers_vms            | dns_servers_vms_vm_id_fkey               | (vm_id) REFERENCES vm(id)
#  inference_endpoint_replica | inference_endpoint_replica_vm_id_fkey    | (vm_id) REFERENCES vm(id)
#  kubernetes_clusters_cp_vms | kubernetes_clusters_cp_vms_cp_vm_id_fkey | (cp_vm_id) REFERENCES vm(id)
#  kubernetes_nodepools_vms   | kubernetes_nodepools_vms_vm_id_fkey      | (vm_id) REFERENCES vm(id)
#  load_balancers_vms         | load_balancers_vms_vm_id_fkey            | (vm_id) REFERENCES vm(id)
#  minio_server               | minio_server_vm_id_fkey                  | (vm_id) REFERENCES vm(id)
#  nic                        | nic_vm_id_fkey                           | (vm_id) REFERENCES vm(id)
#  pci_device                 | pci_device_vm_id_fkey                    | (vm_id) REFERENCES vm(id)
#  postgres_server            | postgres_server_vm_id_fkey               | (vm_id) REFERENCES vm(id)
#  vm_storage_volume          | vm_storage_volume_vm_id_fkey             | (vm_id) REFERENCES vm(id)
