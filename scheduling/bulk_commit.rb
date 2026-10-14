# frozen_string_literal: true

# Commits the allocations of a scheduling round in about ten statements at
# the end of the round, instead of about 25 statements for each VM as
# Scheduling::Allocator::Allocation#update does. Each allocation is
# planned in memory with host data loaded once per host in the round, and
# written with the values Allocation#update would write: a dedicated slice
# with its cpus, the VM's addresses and host, the host and storage device
# usage, and the storage volumes.
class Scheduling::BulkCommit
  HostData = Struct.new(:vm_host, :free_cpus, :free_ipv4, :vetho_ips, :ephemeral_net6s, :backends, :boot_image_ids)
  Plan = Struct.new(:vm, :allocation, :slice, :cpus, :ip4, :address_id, :ephemeral_net6, :local_vetho_ip, :volumes)

  attr_reader :plans

  def initialize
    @hosts = {}
    @plans = []
  end

  # VMs with a dedicated slice and no GPU, on a host with a vhost block
  # backend.
  def plannable?(request, allocation)
    request.use_slices && !request.require_shared_slice && request.gpu_count == 0 &&
      allocation.candidate_host[:accepts_slices] && !host(allocation.vm_host_id).backends.empty?
  end

  # Plans the allocation, and returns the usage it adds to the host.
  def plan(vm, request, allocation)
    host = host(allocation.vm_host_id)
    vm_host = host.vm_host
    threads_per_core = vm_host.total_cpus / vm_host.total_cores
    cpus = take_cpus(host, request.cores_for_vcpus(threads_per_core) * threads_per_core)
    slice = {
      id: VmHostSlice.generate_uuid,
      name: "#{vm.family}_#{vm.inhost_name}",
      family: vm.family,
      cores: cpus.size / threads_per_core,
      total_cpu_percent: cpus.size * 100,
      used_cpu_percent: vm.cpu_percent_limit,
      total_memory_gib: [request.memory_gib_for_vcpus(cpus.size), request.memory_gib].max,
      used_memory_gib: vm.memory_gib,
    }
    ip4, address_id = host.free_ipv4.pop if vm.ip4_enabled
    fail "no ip4 addresses left" if vm.ip4_enabled && !ip4

    storage = allocation.storage_allocation
    @plans << Plan.new(vm, allocation, slice, cpus, ip4, address_id, take_ephemeral_net6(host), take_vetho_ip(host),
      volumes(host, request, storage.volume_to_device_map))

    {
      cores: slice[:cores],
      hugepages_1g: slice[:total_memory_gib],
      ipv4_available: !host.free_ipv4.empty?,
      storage_gib: storage.storage_device_allocations.select { it.allocated_storage_gib > 0 }.to_h { [it.id, it.allocated_storage_gib] },
    }
  end

  def write
    return if @plans.empty?

    now = Time.now
    DB[:vm_host_slice].import(
      [:id, :name, :is_shared, :enabled, :family, :cores, :total_cpu_percent, :used_cpu_percent, :total_memory_gib, :used_memory_gib, :vm_host_id],
      @plans.map { |plan| plan.slice.values_at(:id, :name) + [false, true] + plan.slice.values_at(:family, :cores, :total_cpu_percent, :used_cpu_percent, :total_memory_gib, :used_memory_gib) + [plan.allocation.vm_host_id] },
    )
    DB[:strand].import([:id, :prog, :label], @plans.map { [it.slice[:id], "Vm::VmHostSliceNexus", "prep"] })

    cpu_rows = @plans.flat_map { |plan| plan.cpus.map { [plan.allocation.vm_host_id, it, plan.slice[:id]] } }
    updated = update_from(:vm_host_cpu, [:vm_host_id, :cpu_number, :vm_host_slice_id], cpu_rows,
      where: {Sequel[:vm_host_cpu][:vm_host_id] => uuid(:vm_host_id), Sequel[:vm_host_cpu][:cpu_number] => Sequel[:v][:cpu_number], Sequel[:vm_host_cpu][:vm_host_slice_id] => nil, Sequel[:vm_host_cpu][:io] => false},
      set: {vm_host_slice_id: uuid(:vm_host_slice_id)})
    fail "not all planned cpus were free" unless updated == cpu_rows.size

    update_from(:vm, [:id, :vm_host_id, :ephemeral_net6, :local_vetho_ip, :family, :vm_host_slice_id],
      @plans.map { [it.vm.id, it.allocation.vm_host_id, it.ephemeral_net6, it.local_vetho_ip, it.allocation.candidate_host[:family], it.slice[:id]] },
      where: {Sequel[:vm][:id] => uuid(:id)},
      set: {vm_host_id: uuid(:vm_host_id), ephemeral_net6: Sequel.cast(Sequel[:v][:ephemeral_net6], :cidr), local_vetho_ip: Sequel.cast(Sequel[:v][:local_vetho_ip], :cidr), family: Sequel[:v][:family], vm_host_slice_id: uuid(:vm_host_slice_id), allocated_at: now})

    with_ip4 = @plans.select(&:ip4)
    DB[:assigned_vm_address].import([:id, :dst_vm_id, :ip, :address_id], with_ip4.map { [AssignedVmAddress.generate_uuid, it.vm.id, it.ip4, it.address_id] })
    update_from(:sshable, [:id, :host], @plans.map { [it.vm.id, ssh_host(it)] },
      where: {Sequel[:sshable][:id] => uuid(:id)}, set: {host: Sequel[:v][:host]})

    update_from(:vm_host, [:id, :cores, :hugepages_1g], @plans.group_by { it.allocation.vm_host_id }.map { |id, plans| [id, plans.sum { it.slice[:cores] }, plans.sum { it.slice[:total_memory_gib] }] },
      where: {Sequel[:vm_host][:id] => uuid(:id)},
      set: {used_cores: Sequel[:vm_host][:used_cores] + int(:cores), used_hugepages_1g: Sequel[:vm_host][:used_hugepages_1g] + int(:hugepages_1g)})

    device_usage = Hash.new(0)
    @plans.each { |plan| plan.allocation.storage_allocation.storage_device_allocations.each { device_usage[it.id] += it.allocated_storage_gib } }
    update_from(:storage_device, [:id, :gib], device_usage.to_a,
      where: {Sequel[:storage_device][:id] => uuid(:id)},
      set: {available_storage_gib: Sequel[:storage_device][:available_storage_gib] - int(:gib)})

    update_from(:vm_storage_volume, [:vm_id, :disk_index, :boot_image_id, :vhost_block_backend_id, :storage_device_id, :vring_workers],
      @plans.flat_map { |plan| plan.volumes.map { [plan.vm.id, *it] } },
      where: {Sequel[:vm_storage_volume][:vm_id] => uuid(:vm_id), Sequel[:vm_storage_volume][:disk_index] => int(:disk_index)},
      set: {boot_image_id: uuid(:boot_image_id), vhost_block_backend_id: uuid(:vhost_block_backend_id), storage_device_id: uuid(:storage_device_id),
            vring_workers: int(:vring_workers), use_bdev_ubi: false, spdk_installation_id: nil})

    @plans.each { Clog.emit("vm allocated", {allocation: it.allocation.to_s, duration: now - it.vm.created_at}) }
  end

  private

  def host(id)
    @hosts[id] ||= begin
      vm_host = VmHost[id]
      host_vms = Vm.where(vm_host_id: id)
      HostData.new(
        vm_host,
        VmHostCpu.where(vm_host_id: id, io: false, vm_host_slice_id: nil).order(:numa_node, :cpu_number).select_map([:numa_node, :cpu_number]),
        DB[:ipv4_address].join(:address, [:cidr])
          .where(Sequel[:address][:routed_to_host_id] => id)
          .exclude(DB[:assigned_vm_address].where(ip: Sequel[:ipv4_address][:ip]).select(1).exists)
          .select_map([Sequel[:ipv4_address][:ip], Sequel[:address][:id]])
          .map { |ip, address_id| [ip.to_s, address_id] }
          .shuffle,
        host_vms.exclude(local_vetho_ip: nil).select_map(:local_vetho_ip).to_set { it.network.to_s },
        host_vms.exclude(ephemeral_net6: nil).select_map(:ephemeral_net6).to_set(&:to_s),
        vm_host.vhost_block_backends_dataset.exclude(allocation_weight: 0).all,
        BootImage.where(vm_host_id: id).exclude(activated_at: nil).order(Sequel.desc(:version, nulls: :last)).select_map([:name, :id]).reverse.to_h,
      )
    end
  end

  # Picks cpus as VmHostSliceAllocation#select_cpuset does: the smallest numa
  # node with enough free cpus, else the first free cpus.
  def take_cpus(host, n)
    by_node = host.free_cpus.group_by(&:first)
    node_cpus = by_node.values.select { it.size >= n }.min_by { [it.size, it.first.last] }
    cpus = (node_cpus || host.free_cpus).first(n)
    fail "failed to allocate cpus" if cpus.size < n

    host.free_cpus -= cpus
    cpus.map(&:last)
  end

  def take_ephemeral_net6(host)
    net6 = host.vm_host.ip6_random_vm_network.to_s
    net6 = host.vm_host.ip6_random_vm_network.to_s while host.ephemeral_net6s.include?(net6)
    host.ephemeral_net6s << net6
    net6
  end

  # As VmHost#veth_pair_random_ip4_addr, but also avoiding the addresses
  # planned in the round.
  def take_vetho_ip(host)
    ip = VmHost::APIPA_RANGE.nth(2 * SecureRandom.random_number(VmHost::APIPA_LEN))
    ip = ip.next.next while host.vetho_ips.include?(ip.to_s)
    host.vetho_ips << ip.to_s
    NetAddr::IPv4Net.new(ip, VmHost::APIPA_MASK).to_s
  end

  # The volume columns StorageAllocation#allocate_storage_volume_associations
  # sets for a host with a vhost block backend.
  def volumes(host, request, volume_to_device_map)
    request.storage_volumes.map do |disk_index, params|
      backend_id = Scheduling::Allocator::StorageAllocation.allocate_vhost_block_backend(host.backends.dup, min_version: request.minimum_vhost_block_backend_version)
      boot_image_id = if params["machine_image_version_id"] || params["remote_storage_server_id"]
        nil
      elsif params["boot"]
        host.boot_image_ids.fetch(request.boot_image)
      elsif params["read_only"]
        host.boot_image_ids.fetch(params["image"])
      end
      [disk_index, boot_image_id, backend_id, volume_to_device_map[disk_index], params["vring_workers"]]
    end
  end

  def ssh_host(plan)
    if plan.ip4
      NetAddr::IPv4Net.parse(plan.ip4).nth(0).to_s
    else
      NetAddr::IPv6Net.parse(plan.ephemeral_net6).nth(2).to_s
    end
  end

  def update_from(table, columns, rows, where:, set:)
    DB.from(table, DB.values(rows).as(:v, columns)).where(where).update(set)
  end

  def uuid(column)
    Sequel.cast(Sequel[:v][column], :uuid)
  end

  def int(column)
    Sequel.cast(Sequel[:v][column], :integer)
  end
end
