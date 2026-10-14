# frozen_string_literal: true

class Prog::Vm::Scheduler < Prog::Base
  STRAND_ID = UBID.parse("st0vmschedv13rzzzzzzzzzzzz").to_uuid

  frame_accessor :cursor, :reservations

  label def wait
    reservations = live_reservations
    strands = waiting_strands
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

    if strands.size == Config.central_vm_scheduler_batch_size
      self.cursor = strands.last.id
      nap 0
    end

    self.cursor = nil
    nap 5
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

  # The scheduler locks the strands of the VMs it allocates, and skips the
  # ones that run, so a VM strand never runs while it gets a host. A VM
  # stays in wait_allocation after it gets a host until its strand runs, so
  # only VMs without a host wait. It also skips the VMs of spilled runners,
  # which the runner replaces. Strand ids are VM ids, which are ordered by
  # their creation millisecond.
  def waiting_strands
    ds = Strand.where(prog: "Vm::Metal::Nexus", label: "wait_allocation", exitval: nil)
      .where { lease < Sequel::CURRENT_TIMESTAMP }
      .where(Vm.where(id: Sequel[:strand][:id], vm_host_id: nil).exists)
      .exclude(id: GithubRunner.where(id: Semaphore.where(name: "spill_over").select(:strand_id)).exclude(vm_id: nil).select(:vm_id))
      .order(:id)
      .limit(Config.central_vm_scheduler_batch_size)
    ds = ds.where(Sequel[:id] > cursor) if cursor
    ds.for_no_key_update.skip_locked.all
  end
end
