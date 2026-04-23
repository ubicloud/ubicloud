# frozen_string_literal: true

require "base64"

class Vm < Sequel::Model
  module Metal
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
        to_a.join(":")
      end

      def max_vcpus
        @max_vcpus ||= to_a.reduce(:*)
      end
    end

    def cloud_hypervisor_cpu_topology
      threads_per_core, r = vm_host.total_cpus.divmod vm_host.total_cores
      fail "BUG" unless r.zero?

      total_dies_per_package, r = vm_host.total_dies.divmod vm_host.total_sockets
      fail "BUG" unless r.zero?

      total_packages = vm_host.total_sockets

      # Computed all-system statistics, now scale it down to meet VM needs.
      if vcpus == 1 && threads_per_core > 1
        # special case for single-threaded VMs
        cores_from_cpus = 1r
        threads_per_core = 1
      else
        cores_from_cpus = Rational(vcpus) / threads_per_core
      end
      proportion = cores_from_cpus / vm_host.total_cores
      packages = (total_packages * proportion).ceil
      dies_per_package = (total_dies_per_package * proportion).ceil
      cores_per_die = cores_from_cpus / (packages * dies_per_package)
      fail "BUG: need uniform number of cores allocated per die" unless cores_per_die.denominator == 1

      topo = [threads_per_core, cores_per_die, dies_per_package, packages].map { |num|
        # :nocov:
        fail "BUG: non-integer in topology array" unless num.denominator == 1
        # :nocov:

        Integer(num)
      }

      # :nocov:
      unless topo.reduce(:*) == vcpus
        fail "BUG: arithmetic does not result in the correct number of vcpus"
      end
      # :nocov:

      CloudHypervisorCpuTopo.new(*topo)
    end

    def inhost_name
      self.class.ubid_to_name(UBID.to_ubid(id))
    end

    def healthcheck_systemd_units
      [inhost_name, "#{inhost_name}-dnsmasq"] +
        vm_storage_volumes.filter_map { it.vhost_backend_systemd_unit_name if it.vhost_block_backend }
    end

    def update_spdk_version(version)
      spdk_installation = vm_host.spdk_installations_dataset[version:]
      fail "SPDK version #{version} not found on host" unless spdk_installation

      vm_storage_volumes_dataset.update(spdk_installation_id: spdk_installation.id)
      incr_update_spdk_dependency
    end

    def params_json(swap_size_bytes: nil, hypervisor: nil, ch_version: nil, firmware_version: nil, hugepages: nil)
      topo = cloud_hypervisor_cpu_topology

      project_public_keys = project.get_ff_vm_public_ssh_keys || []

      # B200 GPUs require QEMU
      hypervisor ||= (pci_devices.any? { |pci| pci.device == "2901" }) ? "qemu" : "ch"

      # we don't write secrets to params_json, because it
      # shouldn't be stored in the host for security reasons.
      JSON.pretty_generate(
        vm_name: name,
        public_ipv6: project.get_ff_ipv6_disabled ? nic.private_subnet.random_private_ipv6.to_s : ephemeral_net6.to_s,
        public_ipv4: ip4.to_s,
        local_ipv4: local_vetho_ip.to_s,
        dns_ipv4: nic.private_subnet.net4.nth(2).to_s,
        unix_user:,
        ssh_public_keys: [public_key] + project_public_keys,
        nics: nics.map { [it.private_ipv6.to_s, it.private_ipv4.to_s, it.ubid_to_tap_name, it.mac, it.private_ipv4_gateway] },
        boot_image:,
        max_vcpus: topo.max_vcpus,
        cpu_topology: topo.to_s,
        mem_gib: memory_gib,
        ndp_needed: vm_host.ndp_needed,
        storage_volumes:,
        swap_size_bytes:,
        pci_devices: pci_devices.map { [it.slot, it.iommu_group] },
        gpu_partition_id: gpu_partition&.partition_id,
        slice_name: vm_host_slice&.inhost_name || "system.slice",
        cpu_percent_limit: cpu_percent_limit || 0,
        cpu_burst_percent_limit: cpu_burst_percent_limit || 0,
        hypervisor:,
        ch_version:,
        firmware_version:,
        hugepages:,
        init_script: init_script&.init_script || "",
        ipv6_disabled: project.get_ff_ipv6_disabled || false,
      )
    end

    def storage_volumes
      add_cpus = vm_host.spdk_installations.empty? && !vm_host.accepts_slices

      vm_storage_volumes.map { |s|
        if add_cpus
          spdk_cpus = vm_host.cpus.filter(&:spdk).map(&:cpu_number)
          cpus = spdk_cpus.shuffle.take(s.num_queues)
        end
        {
          "boot" => s.boot,
          "image" => s.boot_image&.name,
          "image_version" => s.boot_image&.version,
          "size_gib" => s.size_gib,
          "device_id" => s.device_id,
          "disk_index" => s.disk_index,
          "encrypted" => !s.key_encryption_key_1.nil?,
          "spdk_version" => s.spdk_version,
          "vhost_block_backend_version" => s.vhost_block_backend_version,
          "use_bdev_ubi" => s.use_bdev_ubi,
          "storage_device" => s.storage_device.name,
          "read_only" => s.size_gib == 0,
          "max_read_mbytes_per_sec" => s.max_read_mbytes_per_sec,
          "max_write_mbytes_per_sec" => s.max_write_mbytes_per_sec,
          "slice_name" => vm_host_slice&.inhost_name || "system.slice",
          "num_queues" => s.num_queues,
          "queue_size" => s.queue_size,
          "copy_on_read" => false,
          "track_written" => s.track_written,
        }.tap { |v|
          v["cpus"] = cpus if add_cpus
          v["archive_source"] = storage_archive_source(s) if s.machine_image_version_id
        }
      }
    end

    def storage_archive_source(sv)
      metal = sv.machine_image_version.metal
      store = metal.store
      kek = sv.key_encryption_key_1

      {
        "bucket" => store.bucket,
        "prefix" => metal.store_prefix,
        "region" => store.region,
        "endpoint" => store.endpoint,
        "encrypted_access_key_id" => kek.encrypt(store.access_key, "archive-access-key"),
        "encrypted_secret_access_key" => kek.encrypt(store.secret_key, "archive-secret-key"),
        "encrypted_archive_kek" => kek.encrypt(Base64.decode64(metal.archive_kek.key), "archive-kek"),
        "autofetch" => true,
      }
    end

    def storage_secrets
      vm_storage_volumes.filter_map { |s|
        if !s.key_encryption_key_1.nil?
          [s.device_id, s.key_encryption_key_1.secret_key_material_hash]
        end
      }.to_h
    end

    def create_storage_volumes(storage_volume_params)
      # Some tests create VMs with two storage volumes, and the shape of
      # StorageKeyEncryptionKey creation query will be the same for both. So,
      # ignore duplicate key errors.
      DB.ignore_duplicate_queries do
        storage_volume_params.each_with_index do |params, index|
          if (miv_id = params[:machine_image_version_id])
            # Lock for share before checking for enabled, so it conflicts with the
            # lock in MachineImage::VersionMetalNexus#destroy acquired when updating
            # enabled to false. This is to serialize the check and update transactions and
            # prevent race conditions.
            mivm = MachineImageVersionMetal.where(id: miv_id).for_share.first
            fail "machine image version #{miv_id} is not available" unless mivm&.enabled
          end

          key_encryption_key = if params[:encrypted]
            StorageKeyEncryptionKey.create_random(auth_data: "#{inhost_name}_#{index}")
          end

          VmStorageVolume.create(
            vm_id: id,
            boot: params[:boot],
            size_gib: params[:size_gib],
            disk_index: index,
            use_bdev_ubi: false,
            max_read_mbytes_per_sec: params[:max_read_mbytes_per_sec],
            max_write_mbytes_per_sec: params[:max_write_mbytes_per_sec],
            track_written: params.fetch(:track_written, false),
            key_encryption_key_1_id: key_encryption_key&.id,
            machine_image_version_id: params[:machine_image_version_id],
          )
        end
      end
    end

    private

    def metal_ip6
      ephemeral_net6&.nth(2)
    end

    def metal_update_firewall_rules_prog
      Prog::Vnet::Metal::UpdateFirewallRules
    end
  end
end
