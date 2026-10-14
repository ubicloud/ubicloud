# frozen_string_literal: true

class Prog::Vm::Scheduler < Prog::Base
  STRAND_ID = UBID.parse("st0vmschedv13rzzzzzzzzzzzz").to_uuid

  # The fields of a waiting VM's frame that its allocation request uses.
  ALLOCATION_FRAME_KEYS = %w[storage_volumes distinct_storage_devices exclude_host_ids exclude_data_centers gpu_count gpu_device force_host_id ch_version].freeze

  frame_accessor :reservations

  # A round places VMs oldest first, taking turns between customers, after
  # the reservation holders. VMs of the same request class ask for the
  # same allocation, so once one of them does not fit, the round skips the
  # rest of its class: they keep their place in line, cost nothing, and
  # cannot block smaller VMs that fit in the gaps. A round ends after it
  # placed central_vm_scheduler_batch_size VMs, or when no class fits.
  label def wait
    reservations = live_reservations
    holders, queue = waiting_queue.partition { reservations.value?(it[:id]) }
    bulk_commit = Scheduling::BulkCommit.new if Config.central_vm_scheduler_bulk_commit
    candidates = if bulk_commit
      Scheduling::Allocator::DeferredCandidateCache.new(bulk_commit:, reservations:, free_provisionings:)
    else
      Scheduling::Allocator::CandidateCache.new(reservations:, free_provisionings:)
    end
    planned = []
    unplannable = []
    allocated_ids = []
    no_capacity = {}
    full_classes = Set.new
    unplaced_ids = []
    batch_size = Config.central_vm_scheduler_batch_size
    more_waiting = false

    (holders + take_turns(queue)).each do |vm|
      if allocated_ids.size + planned.size >= batch_size
        more_waiting = true
        break
      end

      if full_classes.include?(vm[:class])
        unplaced_ids << vm[:id]
      elsif (st = lock_strands([vm[:id]]).first)
        case (result = bulk_commit ? try_plan(st, candidates) : try_allocate(st, candidates))
        when :allocated
          allocated_ids << st.id
        when :planned
          planned << st
        when :unplannable
          unplannable << st
        when Scheduling::Allocator::Request
          no_capacity[st.id] = result
          unplaced_ids << st.id
          full_classes << vm[:class]
        end
      end
    end

    if bulk_commit
      allocated_ids.concat(commit_planned(bulk_commit, planned, unplannable, reservations))
    end

    Strand.where(id: allocated_ids).update(schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW)
    Semaphore.incr(unplaced_ids - Semaphore.where(strand_id: unplaced_ids, name: "waiting_for_capacity").select_map(:strand_id), :waiting_for_capacity)
    spilled_ids = unplaced_ids.empty? ? [] : Scheduling::RunnerSpiller.new.spill(unplaced_ids)
    reservations.delete_if { |_, vm_id| allocated_ids.include?(vm_id) || spilled_ids.include?(vm_id) }
    release_unfitting(reservations, no_capacity)
    reserve(no_capacity.except(*spilled_ids), reservations, candidates)
    self.reservations = reservations

    nap(more_waiting ? 0 : 5)
  end

  # Returns :allocated, the request of a VM that does not fit, or :failed.
  def try_allocate(st, candidates)
    nx = st.load
    SchedulerMetrics.increment("scheduling_checks_total") if nx.runner
    commit_one(nx, candidates)
  end

  def commit_one(nx, candidates)
    request = nx.allocation_request
    DB.transaction(savepoint: true) { candidates.allocate(nx.vm, request) }
    SchedulerMetrics.record_allocation(nx.runner) if nx.runner
    :allocated
  rescue Scheduling::Allocator::NoSpaceLeft
    request
  rescue RuntimeError => ex
    Clog.emit("central vm scheduler failed to allocate vm", Util.exception_to_hash(ex, into: {central_vm_scheduler_failure: {vm: nx.strand.ubid}}))
    :failed
  end

  # As try_allocate, but plans the allocation for the bulk commit. Returns
  # :planned, :unplannable, the request of a VM that does not fit, or
  # :failed.
  def try_plan(st, candidates)
    nx = st.load
    request = nx.allocation_request
    SchedulerMetrics.increment("scheduling_checks_total") if nx.runner
    candidates.plan(nx.vm, request) ? :planned : :unplannable
  rescue Scheduling::Allocator::NoSpaceLeft
    request
  rescue RuntimeError => ex
    Clog.emit("central vm scheduler failed to allocate vm", Util.exception_to_hash(ex, into: {central_vm_scheduler_failure: {vm: st.ubid}}))
    :failed
  end

  # Writes the planned allocations in bulk, then commits the VMs it could
  # not plan one by one, with hosts queried after the bulk write. If the
  # bulk write fails, e.g., as another process took planned capacity, its
  # savepoint undoes it and the planned VMs are committed one by one too.
  # Returns the ids of the VMs that got a host.
  def commit_planned(bulk_commit, planned, unplannable, reservations)
    one_by_one = unplannable
    begin
      DB.transaction(savepoint: true) { bulk_commit.write }
      allocated_ids = planned.map do |st|
        runner = st.load.runner
        SchedulerMetrics.record_allocation(runner) if runner
        st.id
      end
    rescue Sequel::Error, RuntimeError => ex
      Clog.emit("central vm scheduler bulk commit failed", Util.exception_to_hash(ex, into: {central_vm_scheduler_bulk_failure: {vms: planned.size}}))
      allocated_ids = []
      one_by_one = planned + unplannable
    end

    candidates = Scheduling::Allocator::CandidateCache.new(reservations:, free_provisionings:)
    allocated_ids + one_by_one.select { commit_one(it.load, candidates) == :allocated }.map(&:id)
  end

  # An operator can override the configured value live in the frame.
  def free_provisionings
    frame["free_provisionings"] || Config.central_vm_scheduler_free_provisionings
  end

  # A VM keeps its reservation while it waits for allocation. Each round
  # tries the holders first, outside the batch, so a holder gets its host
  # as soon as the host has drained.
  def live_reservations
    reserved = reservations || {}
    waiting_ids = Strand.where(id: reserved.values, prog: "Vm::Metal::Nexus", label: "wait_allocation").select_map(:id)
    reserved.select { |_, vm_id| waiting_ids.include?(vm_id) }
  end

  # A holder that does not fit although its host has drained enough is
  # held back by a filter other than free space, e.g., a boot image, so it
  # would never fit there. Its host, or a host that no longer exists, goes
  # to another VM.
  def release_unfitting(reservations, no_capacity)
    held = reservations.select { |_, vm_id| no_capacity.key?(vm_id) }
    hosts = VmHost.where(id: held.keys).to_hash(:id)
    held.each do |host_id, vm_id|
      request = no_capacity[vm_id]
      if (host = hosts[host_id])
        next if host.total_cores - host.used_cores < request.cores_for_vcpus(host.total_cpus / host.total_cores)
        next if host.total_hugepages_1g - host.used_hugepages_1g < request.memory_gib
      end

      reservations.delete(host_id)
      Clog.emit("central vm scheduler released reservation", {central_vm_scheduler_release: {vm: UBID.to_ubid(vm_id), vm_host: UBID.to_ubid(host_id), reason: host ? "unfitting" : "host gone"}})
    end
  end

  # Large VMs that fit on no host reserve the host closest to fitting them,
  # in queue order, up to the reservation limit.
  def reserve(no_capacity, reservations, candidates)
    no_capacity.each do |vm_id, request|
      break if reservations.size >= Config.central_vm_scheduler_max_reservations
      next if request.vcpus < Config.central_vm_scheduler_reservation_min_vcpus || reservations.value?(vm_id)
      next unless (host_id = candidates.closest_host(request))

      reservations[host_id] = vm_id
      Clog.emit("central vm scheduler reserved host", {central_vm_scheduler_reservation: {vm: UBID.to_ubid(vm_id), vm_host: UBID.to_ubid(host_id)}})
    end
  end

  # A VM stays in wait_allocation after it gets a host until its strand
  # runs, so only VMs without a host wait. The VMs of spilled runners do not
  # wait either, as their runners replace them.
  def waiting_dataset
    Strand.where(Sequel[:strand][:prog] => "Vm::Metal::Nexus", Sequel[:strand][:label] => "wait_allocation", Sequel[:strand][:exitval] => nil)
      .where { Sequel[:strand][:lease] < Sequel::CURRENT_TIMESTAMP }
      .where(Vm.where(id: Sequel[:strand][:id], vm_host_id: nil).exists)
      .exclude(Sequel[:strand][:id] => GithubRunner.where(id: Semaphore.where(name: "spill_over").select(:strand_id)).exclude(vm_id: nil).select(:vm_id))
  end

  # The waiting VMs, oldest first, each with its customer (the installation
  # for runners, the project otherwise) and its request class: everything
  # its allocation request depends on. A VM's age counts from its creation,
  # when it enters the queue; its id does not tell its age.
  def waiting_queue
    not_upgrade_premium = Semaphore.where(strand_id: Sequel[:github_runner][:id], name: "not_upgrade_premium").exists
    waiting_dataset
      .join(:vm, id: Sequel[:strand][:id])
      .left_join(:github_runner, vm_id: Sequel[:vm][:id])
      .select(
        Sequel[:strand][:id], Sequel[:strand][:stack], Sequel[:vm][:created_at],
        Sequel.function(:coalesce, Sequel[:github_runner][:installation_id], Sequel[:vm][:project_id]).as(:customer),
        Sequel[:vm][:vcpus], Sequel[:vm][:memory_gib], Sequel[:vm][:family], Sequel[:vm][:arch], Sequel[:vm][:location_id],
        Sequel[:vm][:boot_image], Sequel[:vm][:ip4_enabled], Sequel[:vm][:project_id], Sequel[:github_runner][:installation_id],
        not_upgrade_premium.as(:not_upgrade_premium),
      )
      .order(Sequel[:vm][:created_at], Sequel[:strand][:id])
      .naked
      .map do |row|
        stack = row.delete(:stack)
        row[:class] = row.except(:id, :customer, :created_at).merge(frame: stack.first.slice(*ALLOCATION_FRAME_KEYS))
        row
      end
  end

  # Orders VMs by their turn within their customer, then by age.
  def take_turns(vms)
    vms.group_by { it[:customer] }.each_value do |customer_vms|
      customer_vms.each_with_index { |vm, turn| vm[:position] = [turn, vm[:created_at], vm[:id]] }
    end
    vms.sort_by { it[:position] }
  end

  # The scheduler locks the strands of the VMs it allocates, and skips the
  # ones that run, so a VM strand never runs while it gets a host.
  def lock_strands(ids)
    strands = waiting_dataset.where(Sequel[:strand][:id] => ids).for_no_key_update.skip_locked.to_hash(:id)
    ids.filter_map { strands[it] }
  end
end
