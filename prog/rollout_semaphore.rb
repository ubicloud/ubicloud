# frozen_string_literal: true

class Prog::RolloutSemaphore < Prog::Base
  semaphore :pause, :destroy
  frame_reader :semaphore, :gap, :initial_gap, :initial_num, :increment
  frame_accessor :remaining, :completed, :next_increment_time

  # semaphore: Name of semaphore to increment.
  # ids: Array of object ids to increment semaphore on.
  # gap: The number of seconds between objects when rolling out the remaining records.
  # initial_gap: The number of seconds between objects when rolling out the
  #              initial records.
  # initial_range: The range of records to use the initial gap. By default, this
  #                will be 10% of the total records, but the number will be clamped
  #                to this range.
  # increment: If true (the default), increments the semaphore. Otherwise, decrements
  #            the semaphore.
  def self.assemble(semaphore:, ids:, gap: 60, initial_gap: gap * 5, initial_range: 2..15, increment: true)
    classes = ids.map { UBID.class_for_ubid(UBID.to_ubid(it)) }
    classes.uniq!
    classes.delete_if { it.semaphore_names.include?(semaphore.to_sym) }
    unless classes.empty?
      raise "Some classes do not support semaphores: #{classes.join(", ")}"
    end

    gap = gap.clamp(5, 3600)
    initial_gap = initial_gap.clamp(5, 86400)
    initial_num = (ids.size / 10).clamp(initial_range)

    Strand.create(
      prog: "RolloutSemaphore",
      label: "start",
      stack: [{
        "semaphore" => semaphore,
        "gap" => gap,
        "initial_gap" => initial_gap,
        "initial_num" => initial_num,
        "remaining" => ids,
        "completed" => [],
        "next_increment_time" => Time.now.to_i,
        "increment" => increment,
      }],
    )
  end

  label def start
    when_pause_set? do
      nap 60 * 60
    end

    unless (next_id = remaining.shift)
      hop_destroy
    end

    time_int = next_increment_time
    now = Time.now.to_i
    time_left = time_int - now
    nap(time_left) if time_left > 0

    if increment
      Semaphore.incr(next_id, semaphore)
    else
      Semaphore.where(strand_id: next_id, name: semaphore).destroy
    end

    completed << next_id
    nap_time = (completed.size >= initial_num) ? gap : initial_gap
    # Also handles remaining/completed modifications due to strand.modified!(:stack)
    self.next_increment_time = now + nap_time

    nap(nap_time)
  end

  label def destroy
    when_destroy_set? do
      pop("rollout completed")
    end

    nap(60 * 60 * 24 * 365)
  end
end
