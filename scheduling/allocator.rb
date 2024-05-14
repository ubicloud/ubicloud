# frozen_string_literal: true

module Scheduling::Allocator
  def self.target_host_utilization
    @@target_host_utilization ||= Config.allocator_target_host_utilization
  end

  def self.allocate(vm, storage_volumes, distinct_storage_devices: false, gpu_enabled: false, allocation_state_filter: ["accepting"], host_filter: [], location_filter: [], location_preference: [])
    request = Request.new(
      vm.id,
      vm.cores,
      vm.mem_gib,
      storage_volumes.map { _1["size_gib"] }.sum,
      storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
      vm.boot_image,
      distinct_storage_devices,
      gpu_enabled,
      vm.ip4_enabled,
      target_host_utilization,
      vm.arch,
      allocation_state_filter,
      host_filter,
      location_filter,
      location_preference
    )
    allocation = Allocation.best_allocation(request)
    fail "#{vm} no space left on any eligible host" unless allocation

    allocation.update(vm)
    Clog.emit("vm allocated") { {allocation: allocation.to_s, duration: Time.now - vm.created_at} }
  end

  Request = Struct.new(:vm_id, :cores, :mem_gib, :storage_gib, :storage_volumes, :boot_image, :distinct_storage_devices, :gpu_enabled, :ip4_enabled,
    :target_host_utilization, :arch_filter, :allocation_state_filter, :host_filter, :location_filter, :location_preference)

  class Allocation
    attr_reader :score

    def self.random_score
      @@max_random_score ||= Config.allocator_max_random_score
      rand(0..@@max_random_score)
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
        .select(Sequel[:vm_host][:id].as(:vm_host_id), :total_cores, :used_cores, :total_hugepages_1g, :used_hugepages_1g, :location, :num_storage_devices, :available_storage_gib, :total_storage_gib, :storage_devices, :total_ipv4, :used_ipv4, Sequel.function(:coalesce, :num_gpus, 0).as(:num_gpus), Sequel.function(:coalesce, :available_gpus, 0).as(:available_gpus), :available_iommu_groups, Sequel.function(:coalesce, :vm_provisioning_count, 0).as(:vm_provisioning_count))
        .where(arch: request.arch_filter)
        .where { (total_hugepages_1g - used_hugepages_1g >= request.mem_gib) }
        .where { (total_cores - used_cores >= request.cores) }
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

      ds = ds.join(:boot_image, Sequel[:vm_host][:id] => Sequel[:boot_image][:vm_host_id])
        .where(Sequel[:boot_image][:name] => request.boot_image)
        .exclude(Sequel[:boot_image][:activated_at] => nil)

      ds = ds.where { used_ipv4 < total_ipv4 } if request.ip4_enabled
      ds = ds.where { available_gpus > 0 } if request.gpu_enabled
      ds = ds.where(Sequel[:vm_host][:id] => request.host_filter) unless request.host_filter.empty?
      ds = ds.where(location: request.location_filter) unless request.location_filter.empty?
      ds = ds.where(allocation_state: request.allocation_state_filter) unless request.allocation_state_filter.empty?
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
      vm.sshable&.update(host: vm.ephemeral_net4 || vm.ephemeral_net6.nth(2))
    end

    def initialize(candidate_host, request)
      @candidate_host = candidate_host
      @request = request
      @vm_host_allocations = [VmHostAllocation.new(:used_cores, candidate_host[:total_cores], candidate_host[:used_cores], request.cores),
        VmHostAllocation.new(:used_hugepages_1g, candidate_host[:total_hugepages_1g], candidate_host[:used_hugepages_1g], request.mem_gib)]
      @device_allocations = [StorageAllocation.new(candidate_host, request)]
      @device_allocations << GpuAllocation.new(candidate_host, request) if request.gpu_enabled
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
        VmHost.dataset.where(id: @candidate_host[:vm_host_id]).update(@vm_host_allocations.map { _1.get_vm_host_update }.reduce(&:merge))
        @device_allocations.each { _1.update(vm, vm_host) }
      end
    end

    def to_s
      "#{UBID.from_uuidish(@request.vm_id)} (arch=#{@request.arch_filter}, cpu=#{@request.cores}, mem=#{@request.mem_gib}, storage=#{@request.storage_gib}) -> #{UBID.from_uuidish(@candidate_host[:vm_host_id])} (cpu=#{@candidate_host[:used_cores]}/#{@candidate_host[:total_cores]}, mem=#{@candidate_host[:used_hugepages_1g]}/#{@candidate_host[:total_hugepages_1g]}, storage=#{@candidate_host[:total_storage_gib] - @candidate_host[:available_storage_gib]}/#{@candidate_host[:total_storage_gib]}), score=#{@score}"
    end

    private

    def calculate_score
      util = @allocations.map { _1.utilization }

      # utilization score, in range [0, 2]
      score = @request.target_host_utilization - util.sum.fdiv(util.size)
      score = score.abs + 1 if score < 0

      # imbalance score, in range [0, 1]
      score += util.max - util.min

      if @candidate_host[:location] == "github-runners"
        # penalty for ongoing vm provisionings on the host
        score += @candidate_host[:vm_provisioning_count] * 0.5

        # penalty for AX161, TODO: remove after migration to AX162
        score += 0.5 if @candidate_host[:total_cores] == 32
      end

      # penalty of 5 if host has a GPU but VM doesn't require a GPU
      score += 5 unless @request.gpu_enabled || @candidate_host[:num_gpus] == 0

      # penalty of 10 if location preference is not honored
      score += 10 unless @request.location_preference.empty? || @request.location_preference.include?(@candidate_host[:location])

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
  end

  class GpuAllocation
    attr_reader
    def initialize(candidate_host, request)
      @used = candidate_host[:num_gpus] - candidate_host[:available_gpus]
      @total = candidate_host[:num_gpus]
      @iommu_group = candidate_host[:available_iommu_groups].sample
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
        .where(iommu_group: @iommu_group)
        .update(vm_id: vm.id).zero?
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
      ).exclude(activated_at: nil).order_by(Sequel.desc(:version)).first

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

        VmStorageVolume.create_with_id(
          vm_id: vm.id,
          boot: volume["boot"],
          size_gib: volume["size_gib"],
          use_bdev_ubi: SpdkInstallation[spdk_installation_id].supports_bdev_ubi? && volume["boot"],
          boot_image_id: volume["boot"] ? allocate_boot_image(vm_host, vm.boot_image) : nil,
          skip_sync: volume["skip_sync"],
          disk_index: disk_index,
          key_encryption_key_1_id: key_encryption_key&.id,
          spdk_installation_id: spdk_installation_id,
          storage_device_id: @volume_to_device_map[disk_index]
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
