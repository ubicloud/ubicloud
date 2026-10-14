# frozen_string_literal: true

class Prog::Vm::Scheduler < Prog::Base
  STRAND_ID = UBID.parse("st0vmschedv13rzzzzzzzzzzzz").to_uuid

  frame_accessor :retry_cursor, :reservations

  label def wait
    reservations = live_reservations
    batch_ids, next_retry_cursor, more_waiting = next_batch
    strands = lock_strands(batch_ids)
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
    reserve(no_capacity.except(*spilled_ids), reservations, candidates)
    self.reservations = reservations

    self.retry_cursor = next_retry_cursor
    nap(more_waiting ? 0 : 5)
  end

  # An operator can override the configured value live in the frame.
  def free_provisionings
    frame["free_provisionings"] || Config.central_vm_scheduler_free_provisionings
  end

  # A VM keeps its reservation while it waits for allocation.
  def live_reservations
    reserved = reservations || {}
    waiting_ids = Strand.where(id: reserved.values, prog: "Vm::Metal::Nexus", label: "wait_allocation").select_map(:id)
    reserved.select { |_, vm_id| waiting_ids.include?(vm_id) }
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

  # Strand ids are VM ids, which are ordered by their creation millisecond.
  # A VM stays in wait_allocation after it gets a host until its strand
  # runs, so only VMs without a host wait. The VMs of spilled runners do not
  # wait either, as their runners replace them.
  def waiting_dataset
    Strand.where(Sequel[:strand][:prog] => "Vm::Metal::Nexus", Sequel[:strand][:label] => "wait_allocation", Sequel[:strand][:exitval] => nil)
      .where { Sequel[:strand][:lease] < Sequel::CURRENT_TIMESTAMP }
      .where(Vm.where(id: Sequel[:strand][:id], vm_host_id: nil).exists)
      .exclude(Sequel[:strand][:id] => GithubRunner.where(id: Semaphore.where(name: "spill_over").select(:strand_id)).exclude(vm_id: nil).select(:vm_id))
  end

  # Picks the VMs of a round. VMs that did not fail to fit yet go first,
  # then the VMs that failed to fit, i.e., retries. Each group takes turns
  # between customers (installations for runners, projects otherwise), so
  # a customer with a large backlog does not delay the others. Retries
  # continue after the retry cursor, their last position in a round, so
  # VMs that still do not fit cannot block the ones behind them. A retry
  # can move to an earlier turn when an older VM of its customer gets a
  # host, and then waits for the next pass over the retries.
  def next_batch
    customer = Sequel.function(:coalesce, Sequel[:github_runner][:installation_id], Sequel[:vm][:project_id])
    failed = Semaphore.where(strand_id: Sequel[:strand][:id], name: "waiting_for_capacity").exists
    fresh, retries = waiting_dataset
      .join(:vm, id: Sequel[:strand][:id])
      .left_join(:github_runner, vm_id: Sequel[:vm][:id])
      .select(Sequel[:strand][:id], customer.as(:customer), failed.as(:failed))
      .order(Sequel[:strand][:id])
      .naked
      .all
      .partition { !it[:failed] }
    retries = take_turns(retries)
    retries.select! { (it[:position] <=> retry_cursor).positive? } if retry_cursor
    queue = take_turns(fresh) + retries
    batch = queue.first(Config.central_vm_scheduler_batch_size)
    more_waiting = queue.size > batch.size
    next_retry_cursor = more_waiting ? (batch.reverse.find { it[:failed] }&.fetch(:position) || retry_cursor) : nil
    [batch.map { it[:id] }, next_retry_cursor, more_waiting]
  end

  # Orders VMs by their turn within their customer, then by id.
  def take_turns(vms)
    vms.group_by { it[:customer] }.each_value do |customer_vms|
      customer_vms.each_with_index { |vm, turn| vm[:position] = [turn, vm[:id]] }
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
