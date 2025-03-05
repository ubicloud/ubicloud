# frozen_string_literal: true

module Scheduling::Allocator
  # :nocov:
  def self.freeze
    target_host_utilization
    super
  end
  # :nocov:

  def self.target_host_utilization
    @target_host_utilization ||= Config.allocator_target_host_utilization
  end

  def self.allocate(vm, storage_volumes, distinct_storage_devices: false, gpu_count: 0, allocation_state_filter: ["accepting"], host_filter: [], host_exclusion_filter: [], location_filter: [], location_preference: [])
    request = Request.new(
      vm.id,
      vm.vcpus,
      vm.memory_gib,
      storage_volumes.map { _1["size_gib"] }.sum,
      storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
      vm.boot_image,
      distinct_storage_devices,
      gpu_count,
      vm.ip4_enabled,
      target_host_utilization,
      vm.arch,
      allocation_state_filter,
      host_filter,
      host_exclusion_filter,
      location_filter,
      location_preference,
      vm.family,
      vm.cpu_percent_limit,
      vm.project.get_ff_use_slices_for_allocation || false,
      Option::VmFamilies.find { _1.name == vm.family }&.require_shared_slice || false,
      vm.project.get_ff_allocator_diagnostics || false
    )
    allocation = Allocation.best_allocation(request)
    fail "#{vm} no space left on any eligible host" unless allocation

    allocation.update(vm)
    Clog.emit("vm allocated") { {allocation: allocation.to_s, duration: Time.now - vm.created_at} }
  end

  Request = Struct.new(
    :vm_id,
    :vcpus,
    :memory_gib,
    :storage_gib,
    :storage_volumes,
    :boot_image,
    :distinct_storage_devices,
    :gpu_count,
    :ip4_enabled,
    :target_host_utilization,
    :arch_filter,
    :allocation_state_filter,
    :host_filter,
    :host_exclusion_filter,
    :location_filter,
    :location_preference,
    :family,
    :cpu_percent_limit,
    :use_slices,
    :require_shared_slice,
    :diagnostics
  ) do
    def initialize(*args)
      super
      self.use_slices ||= false
      self.require_shared_slice ||= false
      self.diagnostics ||= false
    end

    # Computes the amount of memory needed for a slice
    # based on the number of vCPUs requested.
    # Note that the number of vcpus requested for a slice
    # might be different from what is requested for a VM,
    # in case of shared slices (burstable family for now).
    def memory_gib_for_vcpus(vcpus)
      memory_to_cpu_ratio = if arch_filter == "arm64"
        3.2
      elsif family == "standard-gpu"
        5.34
      else
        4
      end

      (vcpus * memory_to_cpu_ratio).to_i
    end

    # Compute the number of cores reserved from the host for
    # a VM. This method is used in two ways:
    # - for a 'standard' family we always have an even number of
    #   vCPUs requested. In that case this simply converts the number
    #   of vCPUs to the number of cores using threads_per_core ratio
    # - for a 'burstable' family this computes the number of cores to
    #   be allocated for a slice hosting the VM. This is when we need to
    #   "adjust" the number of vCPUs to be even, as we always allocate
    #   an even number of vCPUs for a slice.
    def cores_for_vcpus(threads_per_core)
      adjusted_vcpus = (vcpus.odd? && threads_per_core == 1) ? vcpus + 1 : vcpus
      (Float(adjusted_vcpus) / threads_per_core).ceil
    end
  end

  class Allocation
    attr_reader :score

    # :nocov:
    def self.freeze
      random_score
      super
    end
    # :nocov:

    def self.random_score
      @max_random_score ||= Config.allocator_max_random_score
      rand(0..@max_random_score)
    end

    def self.best_allocation(request)
      candidate_hosts(request).map { Allocation.new(_1, request) }
        .select { _1.is_valid }
        .min_by { _1.score + random_score }
    end

    def self.candidate_hosts(request)
      ds = DB[:vm_host]
        .join(:storage_devices, vm_host_id: Sequel[:vm_host][:id])
        .join(:total_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .join(:used_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .left_join(:gpus, vm_host_id: Sequel[:vm_host][:id])
        .left_join(:vm_provisioning, vm_host_id: Sequel[:vm_host][:id])
        .select(
          Sequel[:vm_host][:id].as(:vm_host_id),
          :total_cpus,
          :total_cores,
          :used_cores,
          :total_hugepages_1g,
          :used_hugepages_1g,
          :location_id,
          :num_storage_devices,
          :available_storage_gib,
          :total_storage_gib,
          :storage_devices,
          :total_ipv4,
          :used_ipv4,
          Sequel.function(:coalesce, :num_gpus, 0).as(:num_gpus),
          Sequel.function(:coalesce, :available_gpus, 0).as(:available_gpus),
          :available_iommu_groups,
          Sequel.function(:coalesce, :vm_provisioning_count, 0).as(:vm_provisioning_count),
          :accepts_slices
        )
        .where(arch: request.arch_filter)
        .with(:total_ipv4, DB[:address]
          .select_group(:routed_to_host_id)
          .select_append { round(sum(power(2, 32 - masklen(cidr)))).cast(:integer).as(total_ipv4) }
          .where { (family(cidr) =~ 4) })
        .with(:used_ipv4, DB[:address].left_join(:assigned_vm_address, address_id: :id)
          .select_group(:routed_to_host_id)
          .select_append { (count(Sequel[:assigned_vm_address][:id]) + 1).as(used_ipv4) })
        .with(:storage_devices, DB[:storage_device]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(num_storage_devices) }
          .select_append { sum(available_storage_gib).as(available_storage_gib) }
          .select_append { sum(total_storage_gib).as(total_storage_gib) }
          .select_append { json_agg(json_build_object(Sequel.lit("'id'"), Sequel[:storage_device][:id], Sequel.lit("'total_storage_gib'"), total_storage_gib, Sequel.lit("'available_storage_gib'"), available_storage_gib)).order(available_storage_gib).as(storage_devices) }
          .where(enabled: true)
          .having { sum(available_storage_gib) >= request.storage_gib }
          .having { count.function.* >= (request.distinct_storage_devices ? request.storage_volumes.count : 1) })
        .with(:gpus, DB[:pci_device]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(num_gpus) }
          .select_append { sum(Sequel.case({{vm_id: nil} => 1}, 0)).as(available_gpus) }
          .select_append { array_remove(array_agg(Sequel.case({{vm_id: nil} => :iommu_group}, nil)), nil).as(available_iommu_groups) }
          .where(device_class: ["0300", "0302"]))
        .with(:vm_provisioning, DB[:vm]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(vm_provisioning_count) }
          .where(display_state: "creating"))

      ds = if request.use_slices && request.require_shared_slice
        # We are looking for hosts that have at least once slice already allocated but with enough room
        # for our new VM. This means it has to be a sharable slice, with cpu and memory available
        # We then combine it with search for a host, as usual, with just open space on the host where
        # we could allocate a new slice
        # Later in VmHostSliceAllocator the selected hosts will be scored depending if a slice is reused or
        # new one is created
        ds.with(:slice_utilization, DB[:vm_host_slice]
            .select_group(:vm_host_id)
            .select_append { (sum(Sequel[:total_cpu_percent]) - sum(Sequel[:used_cpu_percent])).as(slice_cpu_available) }
            .select_append { (sum(Sequel[:total_memory_gib]) - sum(Sequel[:used_memory_gib])).as(slice_memory_available) }
            .where(enabled: true)
            .where(is_shared: true)
            .where(Sequel[:used_cpu_percent] + request.cpu_percent_limit <= Sequel[:total_cpu_percent])
            .where(Sequel[:used_memory_gib] + request.memory_gib <= Sequel[:total_memory_gib]))
          # end of 'with'
          .left_join(:slice_utilization, vm_host_id: Sequel[:vm_host][:id])
          .select_append(Sequel.function(:coalesce, :slice_cpu_available, 0).as(:slice_cpu_available))
          .select_append(Sequel.function(:coalesce, :slice_memory_available, 0).as(:slice_memory_available))
          .where {
            ((total_hugepages_1g - used_hugepages_1g >= request.memory_gib) & (total_cores - used_cores >= Sequel.function(:greatest, 1, (request.vcpus * total_cores / total_cpus)))) |
              ((slice_cpu_available > 0) & (slice_memory_available > 0))
          }
      else
        # If we allocate a dedicated VM, it does not matter if it is in a slice or not, we just need to find space for
        # it directly on the host, as we used to. So no slice space computation is involved. A new slice will ALWAYS be
        # allocated for a new VM.
        ds
          .where { (total_hugepages_1g - used_hugepages_1g >= request.memory_gib) }
          .where { (total_cores - used_cores >= Sequel.function(:greatest, 1, (request.vcpus * total_cores / total_cpus))) }
      end

      ds = ds.join(:boot_image, Sequel[:vm_host][:id] => Sequel[:boot_image][:vm_host_id])
        .where(Sequel[:boot_image][:name] => request.boot_image)
        .exclude(Sequel[:boot_image][:activated_at] => nil)

      request.storage_volumes.select { _1[1]["read_only"] && _1[1]["image"] }.map { [_1[0], _1[1]["image"]] }.each do |idx, img|
        table_alias = :"boot_image_#{idx}"
        ds = ds.join(Sequel[:boot_image].as(table_alias), Sequel[:vm_host][:id] => Sequel[table_alias][:vm_host_id])
          .where(Sequel[table_alias][:name] => img)
          .exclude(Sequel[table_alias][:activated_at] => nil)
      end

      ds = ds.where { used_ipv4 < total_ipv4 } if request.ip4_enabled
      ds = ds.where { available_gpus >= request.gpu_count } if request.gpu_count > 0
      ds = ds.where(Sequel[:vm_host][:id] => request.host_filter) unless request.host_filter.empty?
      ds = ds.exclude(Sequel[:vm_host][:id] => request.host_exclusion_filter) unless request.host_exclusion_filter.empty?
      ds = ds.where(location_id: request.location_filter) unless request.location_filter.empty?
      ds = ds.where(allocation_state: request.allocation_state_filter) unless request.allocation_state_filter.empty?
      ds = ds.exclude(total_cores: 14, total_cpus: 14) unless request.family == "standard-gpu"

      # If we dont's want to use slices, place those only on hosts that do not accept them
      # If we require a shared slice (for burstable vm), allocate those only on hosts that accept slices
      # In all other cases, the host's acceptance of slices will determine if the VM is created in a slice or not
      if !request.use_slices
        ds = ds.where(accepts_slices: false)
      elsif request.require_shared_slice
        ds = ds.where(accepts_slices: true)
      end

      # Emit the allocation query if the project is flagged for
      # diagnostics.
      if request.diagnostics
        Clog.emit("Allocator query for vm") do
          {allocator_query: {vm_id: request.vm_id,
                             sql: ds.no_auto_parameterize.sql}}
        end
      end

      ds.all
    end

    def self.update_vm(vm_host, vm)
      ip4, address = vm_host.ip4_random_vm_network if vm.ip4_enabled
      fail "no ip4 addresses left" if vm.ip4_enabled && !ip4
      vm.update(
        vm_host_id: vm_host.id,
        ephemeral_net6: vm_host.ip6_random_vm_network.to_s,
        local_vetho_ip: vm_host.veth_pair_random_ip4_addr.to_s,
        allocated_at: Time.now
      )
      AssignedVmAddress.create_with_id(dst_vm_id: vm.id, ip: ip4.to_s, address_id: address.id) if ip4
      vm.sshable&.update(host: vm.ephemeral_net4 || NetAddr.parse_net(vm.ephemeral_net6).nth(2))
    end

    def initialize(candidate_host, request)
      @candidate_host = candidate_host
      @request = request
      request_cores = request.cores_for_vcpus(candidate_host[:total_cpus] / candidate_host[:total_cores])

      @vm_host_allocations = [VmHostCpuAllocation.new(:used_cores, candidate_host[:total_cores], candidate_host[:used_cores], request_cores),
        VmHostAllocation.new(:used_hugepages_1g, candidate_host[:total_hugepages_1g], candidate_host[:used_hugepages_1g], request.memory_gib)]
      @device_allocations = [StorageAllocation.new(candidate_host, request)]
      @device_allocations << GpuAllocation.new(candidate_host, request) if request.gpu_count > 0

      if request.use_slices && candidate_host[:accepts_slices]
        # Wrap around and replace the host allocations. That way we can control that logic from the slice POV
        @vm_host_allocations = [VmHostSliceAllocation.new(candidate_host, request, @vm_host_allocations)]
      end

      @allocations = @vm_host_allocations + @device_allocations
      @score = calculate_score
    end

    def is_valid
      @allocations.all? { _1.is_valid }
    end

    def update(vm)
      vm_host = VmHost[@candidate_host[:vm_host_id]]
      DB.transaction do
        Allocation.update_vm(vm_host, vm)
        @vm_host_allocations.each { _1.update(vm, vm_host) }
        @device_allocations.each { _1.update(vm, vm_host) }
      end
    end

    def to_s
      "#{UBID.from_uuidish(@request.vm_id)} (arch=#{@request.arch_filter}, vcpus=#{@request.vcpus}, mem=#{@request.memory_gib}, storage=#{@request.storage_gib}) -> #{UBID.from_uuidish(@candidate_host[:vm_host_id])} (cpu=#{@candidate_host[:used_cores]}/#{@candidate_host[:total_cores]}, mem=#{@candidate_host[:used_hugepages_1g]}/#{@candidate_host[:total_hugepages_1g]}, storage=#{@candidate_host[:total_storage_gib] - @candidate_host[:available_storage_gib]}/#{@candidate_host[:total_storage_gib]}), score=#{@score}"
    end

    private

    def calculate_score
      util = @allocations.map { _1.utilization }

      # utilization score, in range [0, 2]
      score = @request.target_host_utilization - util.sum.fdiv(util.size)
      score = score.abs + 1 if score < 0

      # imbalance score, in range [0, 1]
      score += util.max - util.min

      # penalty for ongoing vm provisionings on the host
      score += @candidate_host[:vm_provisioning_count] * 0.5

      # penalty for AX161, TODO: remove after migration to AX162
      score += 0.5 if @candidate_host[:total_cores] == 32

      # penalty if we are trying to allocate into an shared slice but host has none available
      score += 0.5 if @request.require_shared_slice && (@candidate_host[:slice_cpu_available] == 0 || @candidate_host[:slice_memory_available] == 0)

      # penalty of 5 if host has a GPU but VM doesn't require a GPU
      score += 5 unless @request.gpu_count > 0 || @candidate_host[:num_gpus] == 0

      # penalty of 10 if location preference is not honored
      score += 10 unless @request.location_preference.empty? || @request.location_preference.include?(@candidate_host[:location_id])

      score
    end
  end

  class VmHostAllocation
    attr_reader :total, :used, :requested
    def initialize(column, total, used, requested)
      fail "resource '#{column}' uses more than is available: #{used} > #{total}" if used > total
      @column = column
      @total = total
      @used = used
      @requested = requested
    end

    def is_valid
      @requested + @used <= @total
    end

    def utilization
      (@used + @requested).fdiv(@total)
    end

    def get_vm_host_update
      {@column => Sequel[@column] + @requested}
    end

    def update(vm, vm_host)
      VmHost.dataset.where(id: vm_host.id).update([get_vm_host_update].reduce(&:merge))
    end
  end

  class VmHostCpuAllocation < VmHostAllocation
    # in addition to updating the host, also update the number of cores allocated
    # for the VM. Only do this when we do not host the VM inside a slice.
    def update(vm, vm_host)
      super
      vm.update(cores: requested)
    end
  end

  # The VmHostSliceAllocation is used when system is configured
  # to allocate VMs inside VmHostSlice. It wraps around the VmHostAllocation class
  # used otherwise.
  # This class handles two distinct cases - one when a dedicated slice
  # is created for a VM (as in Standard family). In that case it always looks
  # for a place for a new slice and finds a cpu set that will be used for that.
  # The other case is when a shared slice can be used, meaning multiple VMs can be
  # placed inside a slice. In that case the Allocation first looks if the candidate host
  # already has a slice allocated that matches the family of the VM and that
  # has enough room. If so, it will use that. Otherwise, a new slice will be
  # created same way as in the 'dedicated' case.
  # All this logic is split between 'select_existing_slice' and 'update' methods. The first
  # one checks if the candidate_host can host a slice or has one already.
  # The second one creates a slice if needed, once the host candidate is selected.
  class VmHostSliceAllocation
    def initialize(candidate_host, request, vm_host_allocations)
      @candidate_host = candidate_host
      @request = request
      @vm_host_allocations = vm_host_allocations

      @existing_slice = select_existing_slice if @request.require_shared_slice
    end

    def is_valid
      if @existing_slice
        true
      else
        @vm_host_allocations.all?(&:is_valid)
      end
    end

    def utilization
      if @existing_slice
        # if we found an existing slice, return the desired utilization
        # to make this a preferred choice
        @request.target_host_utilization
      else
        # otherwise, compute the score based on combined CPU and Memory utilization, as usual
        util = @vm_host_allocations.map(&:utilization)
        util.sum.fdiv(util.size)
      end
    end

    def update(vm, vm_host)
      DB.transaction do
        if @existing_slice
          # update the VM
          vm.update(vm_host_slice_id: @existing_slice.id)

          # update the allocation on the VM
          #
          # if we cannot update the slice, likely because it was
          # marked to be destroyed in parallel, we need to fail
          # and start the allocation process again
          updated = VmHostSlice.dataset
            .where(id: @existing_slice.id, enabled: true)
            .update(
              used_cpu_percent: Sequel[:used_cpu_percent] + vm.cpu_percent_limit,
              used_memory_gib: Sequel[:used_memory_gib] + vm.memory_gib
            )

          fail "failed to update slice" unless updated == 1
        else
          # We compute the number of cores that we need to give to the
          # slice, from the number of requested vCPUs. Then we convert
          # it back to CPUs for the host cpu allocation.
          # This may seem redundant but it is neccessary for cases
          # like 1-vcpu VM.
          threads_per_core = vm_host.total_cpus / vm_host.total_cores
          request_cores = @request.cores_for_vcpus(threads_per_core)
          slice_cpus = request_cores * threads_per_core
          cpus = select_cpuset(vm_host.id, slice_cpus)

          st = Prog::Vm::VmHostSliceNexus.assemble_with_host(
            "#{vm.family}_#{vm.inhost_name}",
            vm_host,
            family: vm.family,
            allowed_cpus: cpus,
            memory_gib: @request.memory_gib_for_vcpus(cpus.count),
            is_shared: @request.require_shared_slice
          )

          # update the VM
          vm.update(vm_host_slice_id: st.subject.id)

          # update the allocation on the VM
          # we are updating a newly created slice, so not checking for 'enabled' flag
          VmHostSlice.dataset.where(id: vm.vm_host_slice_id).update(
            used_cpu_percent: Sequel[:used_cpu_percent] + vm.cpu_percent_limit,
            used_memory_gib: Sequel[:used_memory_gib] + vm.memory_gib
          )

          # Update the host utilization
          # Use the values of memory and cores from the slice, not from the request
          # as that is what we are taking away from the host when reserving a slice
          # Slice destruction will return those to the host
          VmHost.dataset.where(id: vm_host.id).update(
            used_cores: Sequel[:used_cores] + st.subject.cores,
            used_hugepages_1g: Sequel[:used_hugepages_1g] + st.subject.total_memory_gib
          )
        end
      end
    end

    def select_cpuset(vm_host_id, n)
      # select the cpuset for the new slice
      cpus = VmHostCpu
        .where(vm_host_id: vm_host_id, spdk: false, vm_host_slice_id: nil)
        .order_by(Sequel.asc(:cpu_number))
        .limit(n)
        .map(&:cpu_number)

      fail "failed to allocate cpus" if cpus.size != n

      cpus
    end

    def select_existing_slice
      vm_host = VmHost[@candidate_host[:vm_host_id]]

      # Try to find an existing slice with some room
      vm_host.slices
        .select {
          (_1.used_cpu_percent + @request.cpu_percent_limit <= _1.total_cpu_percent) &&
            (_1.used_memory_gib + @request.memory_gib <= _1.total_memory_gib) &&
            (_1.cores == @request.cores_for_vcpus(vm_host.total_cpus / vm_host.total_cores)) &&
            (_1.family == @request.family) &&
            _1.enabled
        }
        .min_by { _1.used_cpu_percent }
    end
  end

  class GpuAllocation
    attr_reader
    def initialize(candidate_host, request)
      @used = candidate_host[:num_gpus] - candidate_host[:available_gpus]
      @total = candidate_host[:num_gpus]
      @requested = request.gpu_count
      @iommu_groups = candidate_host[:available_iommu_groups].take(@requested)
    end

    def is_valid
      @used < @total
    end

    def utilization
      (@used + 1).fdiv(@total)
    end

    def update(vm, vm_host)
      fail "concurrent GPU allocation" if
      PciDevice.dataset
        .where(vm_host_id: vm_host.id)
        .where(vm_id: nil)
        .where(iommu_group: @iommu_groups)
        .update(vm_id: vm.id) < @requested
    end
  end

  class StorageAllocation
    attr_reader :is_valid, :total, :used, :requested, :volume_to_device_map
    def initialize(candidate_host, request)
      @candidate_host = candidate_host
      @request = request
      @is_valid = map_volumes_to_devices
    end

    def update(vm, vm_host)
      @storage_device_allocations.each { _1.update }
      create_storage_volumes(vm, vm_host)
    end

    def utilization
      1 - (@candidate_host[:available_storage_gib] - @request.storage_gib).fdiv(@candidate_host[:total_storage_gib])
    end

    def self.allocate_spdk_installation(spdk_installations)
      total_weight = spdk_installations.sum(&:allocation_weight)
      fail "Total weight of all eligible spdk_installations shouldn't be zero." if total_weight == 0

      rand_point = rand(0..total_weight - 1)
      weight_sum = 0
      rand_choice = spdk_installations.each { |si|
        weight_sum += si.allocation_weight
        break si if weight_sum > rand_point
      }
      rand_choice.id
    end

    private

    def allocate_boot_image(vm_host, boot_image_name)
      boot_image = BootImage.where(
        vm_host_id: vm_host.id,
        name: boot_image_name
      ).exclude(activated_at: nil).order_by(Sequel.desc(:version, nulls: :last)).first

      boot_image.id
    end

    def map_volumes_to_devices
      return false if @candidate_host[:available_storage_gib] < @request.storage_gib
      @storage_device_allocations = @candidate_host[:storage_devices].map { StorageDeviceAllocation.new(_1["id"], _1["available_storage_gib"]) }

      @volume_to_device_map = {}
      @request.storage_volumes.each do |vol_id, vol|
        dev = @storage_device_allocations.detect { |dev| dev.available_storage_gib >= vol["size_gib"] && !(@request.distinct_storage_devices && dev.allocated_storage_gib > 0) }
        return false if dev.nil?
        @volume_to_device_map[vol_id] = dev.id
        dev.allocate(vol["size_gib"])
      end
      true
    end

    def create_storage_volumes(vm, vm_host)
      @request.storage_volumes.each do |disk_index, volume|
        spdk_installation_id = StorageAllocation.allocate_spdk_installation(vm_host.spdk_installations)

        key_encryption_key = if volume["encrypted"]
          key_wrapping_algorithm = "aes-256-gcm"
          cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
          key_wrapping_key = cipher.random_key
          key_wrapping_iv = cipher.random_iv

          StorageKeyEncryptionKey.create_with_id(
            algorithm: key_wrapping_algorithm,
            key: Base64.encode64(key_wrapping_key),
            init_vector: Base64.encode64(key_wrapping_iv),
            auth_data: "#{vm.inhost_name}_#{disk_index}"
          )
        end

        image_id = if volume["boot"]
          allocate_boot_image(vm_host, vm.boot_image)
        elsif volume["read_only"]
          allocate_boot_image(vm_host, volume["image"])
        end

        VmStorageVolume.create_with_id(
          vm_id: vm.id,
          boot: volume["boot"],
          size_gib: volume["size_gib"],
          use_bdev_ubi: SpdkInstallation[spdk_installation_id].supports_bdev_ubi? && volume["boot"],
          boot_image_id: image_id,
          skip_sync: volume["skip_sync"],
          disk_index: disk_index,
          key_encryption_key_1_id: key_encryption_key&.id,
          spdk_installation_id: spdk_installation_id,
          storage_device_id: @volume_to_device_map[disk_index],
          max_ios_per_sec: volume["max_ios_per_sec"],
          max_read_mbytes_per_sec: volume["max_read_mbytes_per_sec"],
          max_write_mbytes_per_sec: volume["max_write_mbytes_per_sec"]
        )
      end
    end

    class StorageDeviceAllocation
      attr_reader :id, :available_storage_gib, :allocated_storage_gib

      def initialize(id, available_storage_gib)
        @id = id
        @available_storage_gib = available_storage_gib
        @allocated_storage_gib = 0
      end

      def allocate(size_gib)
        @available_storage_gib -= size_gib
        @allocated_storage_gib += size_gib
      end

      def update
        StorageDevice.dataset.where(id: id).update(available_storage_gib: Sequel[:available_storage_gib] - @allocated_storage_gib) if @allocated_storage_gib > 0
      end
    end
  end
end
