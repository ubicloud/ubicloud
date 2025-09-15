# frozen_string_literal: true

class Prog::Vm::Nexus < Prog::Base
  DEFAULT_SIZE = "standard-2"

  subject_is :vm

  def self.assemble(public_key, project_id, name: nil, size: DEFAULT_SIZE,
    unix_user: "ubi", location_id: Location::HETZNER_FSN1_ID, boot_image: Config.default_boot_image_name,
    private_subnet_id: nil, nic_id: nil, storage_volumes: nil, boot_disk_index: 0,
    enable_ip4: false, pool_id: nil, arch: "x64", swap_size_bytes: nil,
    distinct_storage_devices: false, force_host_id: nil, exclude_host_ids: [], gpu_count: 0, gpu_device: nil,
    hugepages: true, hypervisor: nil, ch_version: nil, firmware_version: nil, new_private_subnet_name: nil,
    exclude_availability_zones: [], availability_zone: nil, alternative_families: [],
    allow_private_subnet_in_other_project: false, init_script: nil, detachable_volume_ids: nil)

    unless (project = Project[project_id])
      fail "No existing project"
    end
    if exclude_host_ids.include?(force_host_id)
      fail "Cannot force and exclude the same host"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    vm_size = Validation.validate_vm_size(size, arch)
    Validation.validate_billing_rate("VmVCpu", vm_size.family, location.name)

    storage_volumes ||= [{
      size_gib: vm_size.storage_size_options.first,
      encrypted: true
    }]

    # allow missing fields to make testing during development more convenient.
    storage_volumes.each_with_index do |volume, disk_index|
      volume[:size_gib] ||= vm_size.storage_size_options.first
      volume[:skip_sync] ||= false
      volume[:max_read_mbytes_per_sec] ||= vm_size.io_limits.max_read_mbytes_per_sec
      volume[:max_write_mbytes_per_sec] ||= vm_size.io_limits.max_write_mbytes_per_sec
      volume[:vring_workers] ||= vm_size.vring_workers
      volume[:encrypted] = true if !volume.has_key? :encrypted
      volume[:boot] = disk_index == boot_disk_index

      if volume[:read_only]
        volume[:size_gib] = 0
        volume[:encrypted] = false
        volume[:skip_sync] = true
        volume[:boot] = false
      end
    end

    Validation.validate_storage_volumes(storage_volumes, boot_disk_index)

    ubid = Vm.generate_ubid
    name ||= Vm.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_os_user_name(unix_user)

    DB.transaction do
      # Here the logic is the following;
      # - If the user provided nic_id, that nic has to exist and we fetch private_subnet
      # from the reference of nic. We just assume it and not even check the validity of the
      # private_subnet_id.
      # - If the user did not provide nic_id but the private_subnet_id, that private_subnet
      # must exist, otherwise we fail.
      # - If the user did not provide nic_id but the private_subnet_id and that subnet exists
      # then we create a nic on that subnet.
      # - If the user provided neither nic_id nor private_subnet_id, that's OK, we create both.
      nic = nil
      subnet = if nic_id
        nic = Nic[nic_id]
        raise("Given nic doesn't exist with the id #{nic_id}") unless nic
        raise("Given nic is assigned to a VM already") if nic.vm_id
        raise("Given nic is created in a different location") if nic.private_subnet.location_id != location.id
        raise("Given nic is not available in the given project") unless project.private_subnets.any? { |ps| ps.id == nic.private_subnet_id }

        nic.private_subnet
      end

      unless nic
        subnet = if private_subnet_id
          subnet = PrivateSubnet[private_subnet_id]
          raise "Given subnet doesn't exist with the id #{private_subnet_id}" unless subnet
          unless allow_private_subnet_in_other_project
            raise "Given subnet is not available in the given project" unless project.private_subnets.any? { |ps| ps.id == subnet.id }
          end

          subnet
        elsif new_private_subnet_name
          Prog::Vnet::SubnetNexus.assemble(project_id, name: new_private_subnet_name, location_id:).subject
        else
          project.default_private_subnet(location)
        end
        nic = Prog::Vnet::NicNexus.assemble(subnet.id, name: "#{name}-nic", exclude_availability_zones: exclude_availability_zones, availability_zone: availability_zone).subject
      end

      vm = Vm.create(
        public_key: public_key,
        unix_user: unix_user,
        name: name,
        family: vm_size.family,
        cores: 0, # this will be updated after allocation is complete based on the host's topology
        vcpus: vm_size.vcpus,
        cpu_percent_limit: vm_size.cpu_percent_limit,
        cpu_burst_percent_limit: vm_size.cpu_burst_percent_limit,
        memory_gib: vm_size.memory_gib,
        location_id: location.id,
        boot_image: boot_image,
        ip4_enabled: enable_ip4,
        pool_id: pool_id,
        arch: arch,
        project_id:
      ) { it.id = ubid.to_uuid }
      nic.update(vm_id: vm.id)

      if init_script && !init_script.empty?
        VmInitScript.create_with_id(vm, init_script:)
      end

      detachable_volume_ids&.each do |dv_id|
        dv = DetachableVolume[dv_id]
        raise "Detachable volume #{dv_id} doesn't exist" unless dv
        raise "Detachable volume #{dv_id} is not available in the given project" unless project.detachable_volumes.any? { |v| v.id == dv.id }
        raise "Detachable volume #{dv_id} is already attached to a VM" if dv.vm_id
        dv.update(vm_id: vm.id)
      end

      if vm_size.family == "standard-gpu"
        gpu_count = 1
        gpu_device = "27b0"
      end

      prog = if location.aws?
        disk_index = 0
        storage_volumes.each do |volume|
          max_disk_size = (vm_size.family == "i8g") ? 3750.0 : 1900.0
          disk_count = (volume[:size_gib] / max_disk_size).ceil

          disk_count.times do
            VmStorageVolume.create(
              vm_id: vm.id,
              size_gib: volume[:size_gib] / disk_count,
              boot: volume[:boot],
              use_bdev_ubi: false,
              disk_index:
            )

            disk_index += 1
          end
        end
        "Vm::Aws::Nexus"
      else
        "Vm::Metal::Nexus"
      end

      Strand.create(
        prog:,
        label: "start",
        stack: [{
          "storage_volumes" => storage_volumes.map { |v| v.transform_keys(&:to_s) },
          "swap_size_bytes" => swap_size_bytes,
          "distinct_storage_devices" => distinct_storage_devices,
          "force_host_id" => force_host_id,
          "exclude_host_ids" => exclude_host_ids,
          "gpu_count" => gpu_count,
          "gpu_device" => gpu_device,
          "hugepages" => hugepages,
          "hypervisor" => hypervisor,
          "ch_version" => ch_version,
          "firmware_version" => firmware_version,
          "alternative_families" => alternative_families
        }]
      ) { it.id = vm.id }
    end
  end

  def self.assemble_with_sshable(*, sshable_unix_user: "rhizome", **kwargs)
    ssh_key = SshKey.generate
    st = assemble(ssh_key.public_key, *, **kwargs)
    Sshable.create_with_id(st, unix_user: sshable_unix_user, host: "temp_#{st.id}", raw_private_key_1: ssh_key.keypair)
    st
  end
end
