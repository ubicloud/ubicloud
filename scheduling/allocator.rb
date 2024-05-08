# frozen_string_literal: true

module Scheduling::Allocator
  def self.allocate(vm, storage_volumes, target_host_utilization: 0.65, distinct_storage_devices: false, allocation_state_filter: ["accepting"], host_filter: [], location_filter: [], location_preference: [])
    request = Request.new(
      vm.id,
      vm.cores,
      vm.mem_gib,
      storage_volumes.map { _1["size_gib"] }.sum,
      storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
      distinct_storage_devices,
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

  Request = Struct.new(:vm_id, :cores, :mem_gib, :storage_gib, :storage_volumes, :distinct_storage_devices, :ip4_enabled, :target_host_utilization,
    :arch_filter, :allocation_state_filter, :host_filter, :location_filter, :location_preference)

  class Allocation
    attr_reader :score

    def self.best_allocation(request)
      candidate_hosts(request).map { Allocation.new(_1, request) }
        .select { _1.is_valid }
        .min_by { _1.score }
    end

    def self.candidate_hosts(request)
      ds = DB[:vm_host]
        .join(:storage_devices, vm_host_id: Sequel[:vm_host][:id])
        .join(:total_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .join(:used_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .select(:vm_host_id, :total_cores, :used_cores, :total_hugepages_1g, :used_hugepages_1g, :location, :num_storage_devices, :available_storage_gib, :total_storage_gib, :storage_devices, :total_ipv4, :used_ipv4)
        .where(allocation_state: request.allocation_state_filter)
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

      ds = ds.where { used_ipv4 < total_ipv4 } if request.ip4_enabled
      ds = ds.where(vm_host_id: request.host_filter) unless request.host_filter.empty?
      ds = ds.where(location: request.location_filter) unless request.location_filter.empty?
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
      @storage_allocation = StorageAllocation.new(candidate_host, request)
      @allocations = @vm_host_allocations + [@storage_allocation]
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
        @storage_allocation.update(vm, vm_host)
      end
    end

    def to_s
      "#{UBID.from_uuidish(@request.vm_id)} (arch=#{@request.arch_filter}, cpu=#{@request.cores}, mem=#{@request.mem_gib}, storage=#{@request.storage_gib}) -> #{UBID.from_uuidish(@candidate_host[:vm_host_id])} (cpu=#{@candidate_host[:used_cores]}/#{@candidate_host[:total_cores]}, mem=#{@candidate_host[:used_hugepages_1g]}/#{@candidate_host[:total_hugepages_1g]}, storage=#{@candidate_host[:total_storage_gib] - @candidate_host[:available_storage_gib]}/#{@candidate_host[:total_storage_gib]}), score=#{@score}"
    end

    private

    def calculate_score
      util = @allocations.map { _1.utilization }

      # utilization score, in range [0, 2]
      avg_util = util.sum.fdiv(util.size)
      utilization_score = @request.target_host_utilization - avg_util
      utilization_score = utilization_score.abs + 1 if utilization_score < 0

      # imbalance score, in range [0, 1]
      imbalance_score = util.max - util.min

      # location preference. 0 if preference is honored, 10 otherwise
      location_preference_score = (@request.location_preference.empty? || @request.location_preference.include?(@candidate_host[:location])) ? 0 : 10

      utilization_score + imbalance_score + location_preference_score
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
