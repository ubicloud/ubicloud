# frozen_string_literal: true

class Prog::Vm::Scheduler < Prog::Base
  STRAND_ID = UBID.parse("st0vmschedv13rzzzzzzzzzzzz").to_uuid

  frame_accessor :cursor

  label def wait
    strands = waiting_strands
    candidates = Scheduling::Allocator::CandidateCache.new
    allocated_ids = []
    no_capacity_ids = []

    strands.each do |st|
      nx = st.load
      DB.transaction(savepoint: true) { candidates.allocate(nx.vm, nx.allocation_request) }
      allocated_ids << st.id
    rescue Scheduling::Allocator::NoSpaceLeft
      no_capacity_ids << st.id
    rescue RuntimeError => ex
      Clog.emit("central vm scheduler failed to allocate vm", Util.exception_to_hash(ex, into: {central_vm_scheduler_failure: {vm: st.ubid}}))
    end

    Strand.where(id: allocated_ids).update(schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW)
    Semaphore.incr(no_capacity_ids - Semaphore.where(strand_id: no_capacity_ids, name: "waiting_for_capacity").select_map(:strand_id), :waiting_for_capacity)

    if strands.size == Config.central_vm_scheduler_batch_size
      self.cursor = [Vm.where(id: strands.last.id).get(:created_at).utc.iso8601(6), strands.last.id]
      nap 0
    end

    self.cursor = nil
    nap 5
  end

  # The scheduler locks the strands of the VMs it allocates, and skips the
  # ones that run, so a VM strand never runs while it gets a host. A VM
  # stays in wait_allocation after it gets a host until its strand runs, so
  # only VMs without a host wait. They wait oldest first: in the order of
  # their creation, then of their id, as an id does not tell its age.
  def waiting_strands
    created_at = Vm.where(id: Sequel[:strand][:id]).select(:created_at)
    ds = Strand.where(prog: "Vm::Metal::Nexus", label: "wait_allocation", exitval: nil)
      .where { lease < Sequel::CURRENT_TIMESTAMP }
      .where(Vm.where(id: Sequel[:strand][:id], vm_host_id: nil).exists)
      .order(created_at, :id)
      .limit(Config.central_vm_scheduler_batch_size)
    ds = ds.where(Sequel.lit("(?, ?) > (?::timestamptz, ?::uuid)", created_at, Sequel[:strand][:id], *cursor)) if cursor
    ds.for_no_key_update.skip_locked.all
  end
end
