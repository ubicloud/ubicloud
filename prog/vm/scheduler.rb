# frozen_string_literal: true

class Prog::Vm::Scheduler < Prog::Base
  STRAND_ID = UBID.parse("st0vmschedv13rzzzzzzzzzzzz").to_uuid

  frame_accessor :retry_cursor, :reservations

  label def wait
    reservations = live_reservations
    holder_ids = reservations.values
    batch_ids, next_retry_cursor, more_waiting = next_batch(holder_ids)
    strands = lock_strands(holder_ids + batch_ids)
    candidates = Scheduling::Allocator::CandidateCache.new(reservations:, free_provisionings:)
    allocated_ids = []
    no_capacity = {}

    strands.each do |st|
      nx = st.load
      request = nx.allocation_request
      DB.transaction(savepoint: true) { candidates.allocate(nx.vm, request) }
      allocated_ids << st.id
    rescue Scheduling::Allocator::NoSpaceLeft
      no_capacity[st.id] = request
    rescue RuntimeError => ex
      Clog.emit("central vm scheduler failed to allocate vm", Util.exception_to_hash(ex, into: {central_vm_scheduler_failure: {vm: st.ubid}}))
    end

    no_capacity_ids = no_capacity.keys
    Strand.where(id: allocated_ids).update(schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW)
    Semaphore.incr(no_capacity_ids - Semaphore.where(strand_id: no_capacity_ids, name: "waiting_for_capacity").select_map(:strand_id), :waiting_for_capacity)
    spilled_ids = no_capacity.empty? ? [] : Scheduling::RunnerSpiller.new.spill(no_capacity_ids)
    reservations.delete_if { |_, vm_id| allocated_ids.include?(vm_id) || spilled_ids.include?(vm_id) }
    release_unfitting(reservations, no_capacity)
    reserve(no_capacity.except(*spilled_ids), reservations, candidates)
    self.reservations = reservations

    self.retry_cursor = next_retry_cursor
    nap(more_waiting ? 0 : 5)
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

  # Picks the VMs of a round, oldest first: in the order of their creation,
  # then of their id, as an id does not tell its age. VMs that did not fail
  # to fit yet go first, then the VMs that failed to fit, i.e., retries.
  # Each group takes turns between customers (installations for runners,
  # projects otherwise), so a customer with a large backlog does not delay
  # the others. Retries continue after the retry cursor, their last position
  # in a round, so VMs that still do not fit cannot block the ones behind
  # them. A retry can move to an earlier turn when an older VM of its
  # customer gets a host, and then waits for the next pass over the retries.
  def next_batch(skip_ids)
    customer = Sequel.function(:coalesce, Sequel[:github_runner][:installation_id], Sequel[:vm][:project_id])
    failed = Semaphore.where(strand_id: Sequel[:strand][:id], name: "waiting_for_capacity").exists
    fresh, retries = waiting_dataset
      .join(:vm, id: Sequel[:strand][:id])
      .left_join(:github_runner, vm_id: Sequel[:vm][:id])
      .select(Sequel[:strand][:id], Sequel[:vm][:created_at], customer.as(:customer), failed.as(:failed))
      .order(Sequel[:vm][:created_at], Sequel[:strand][:id])
      .naked
      .all
      .reject { skip_ids.include?(it[:id]) }
      .partition { !it[:failed] }
    retries = take_turns(retries)
    retries.select! { (it[:position] <=> retry_cursor).positive? } if retry_cursor
    queue = take_turns(fresh) + retries
    batch = queue.first(Config.central_vm_scheduler_batch_size)
    more_waiting = queue.size > batch.size
    next_retry_cursor = more_waiting ? (batch.reverse.find { it[:failed] }&.fetch(:position) || retry_cursor) : nil
    [batch.map { it[:id] }, next_retry_cursor, more_waiting]
  end

  # Orders VMs by their turn within their customer, then by age. A position
  # holds the creation time as a string, as the retry cursor keeps it in the
  # frame.
  def take_turns(vms)
    vms.group_by { it[:customer] }.each_value do |customer_vms|
      customer_vms.each_with_index { |vm, turn| vm[:position] = [turn, vm[:created_at].utc.iso8601(6), vm[:id]] }
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
