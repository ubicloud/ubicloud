# frozen_string_literal: true

class SemSnap
  def initialize(strand_id, deferred: false)
    @deferred = deferred
    @strand_id = strand_id
    @extant = Hash.new { |h, k| h[k.intern] = [] }
    @defer_delete = []

    Semaphore.where(strand_id: @strand_id).each do |sem|
      add_semaphore_instance_to_snapshot(sem)
    end
  end

  def self.use(strand_id)
    new(strand_id, deferred: true).use do |snap|
      yield snap
    end
  end

  def use
    yield self
  ensure
    apply
  end

  def set?(name)
    name = name.intern
    @extant.include?(name)
  end

  def decr(name)
    name = name.intern
    ids = @extant.delete(name)
    return unless ids && ids.length > 0
    @defer_delete.concat(ids)
    apply unless @deferred
  end

  def incr(name)
    add_semaphore_instance_to_snapshot(Semaphore.incr(@strand_id, name))
  end

  private

  def apply
    return if @defer_delete.empty?
    Semaphore.where(strand_id: @strand_id, id: Sequel.any_uuid(@defer_delete)).destroy
    @defer_delete.clear
  end

  def add_semaphore_instance_to_snapshot(sem)
    @extant[sem.name.intern] << sem.id
  end
end
