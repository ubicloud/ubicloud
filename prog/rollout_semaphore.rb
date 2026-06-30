# frozen_string_literal: true

class Prog::RolloutSemaphore < Prog::Base
  semaphore :pause, :destroy
  frame_reader :semaphore, :gap, :initial_gap, :initial_num, :increment, :wait_label
  frame_accessor :remaining, :completed, :next_increment_time, :current

  ALLOWED_SEMAPHORES_PER_RESOURCE_TYPE = {
    KubernetesCluster => [:install_csi],
    LoadBalancer => [:rewrite_dns_records, :refresh_cert, :update_load_balancer],
    Page => [:resolve, :retrigger],
    PostgresResource => [:refresh_dns_record, :refresh_certificates],
    PostgresServer => [:install_rhizome, :configure, :refresh_walg_credentials],
    Vm => [:update_firewall_rules, :restart],
    VmHost => [:patch],
  }.freeze.each_value(&:freeze)

  ALLOWED_SEMAPHORES_PER_RESOURCE_TYPE.each do |klass, semaphores|
    incorrect_semaphores = semaphores - klass.semaphore_names
    # :nocov:
    unless incorrect_semaphores.empty?
      raise "invalid allowed semaphores for #{klass}: #{incorrect_semaphores}"
    end
    # :nocov:
  end

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
  # wait: When incrementing, wait until the semaphore has been decremented. If given a
  #       string, also wait until the strand is at this label before continuing.
  def self.assemble(semaphore:, ids:, gap: 60, initial_gap: gap * 5, initial_range: 2..15, increment: true, wait: true)
    classes = ids.map { UBID.class_for_ubid(UBID.to_ubid(it)) }.uniq

    raise "There cannot be more than one class type in a rollout" unless classes.count == 1
    klass = classes.first
    semaphore_sym = semaphore.to_sym

    unless ALLOWED_SEMAPHORES_PER_RESOURCE_TYPE.fetch(klass, [].freeze).include?(semaphore_sym)
      raise "Semaphore #{semaphore.inspect} is not allow-listed for #{klass.name}"
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
        "current" => nil,
        "completed" => [],
        "next_increment_time" => Time.now.to_i,
        "increment" => increment,
        "wait_label" => wait,
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

    nap_time = (completed.size >= initial_num) ? gap : initial_gap
    # Also handles remaining/completed modifications due to strand.modified!(:stack)
    self.next_increment_time = now + nap_time

    if increment
      Semaphore.incr(next_id, semaphore)
      if wait_label
        self.current = next_id
        hop_wait_current
      end
    else
      Semaphore.where(strand_id: next_id, name: semaphore).destroy
    end

    completed << next_id
    nap(nap_time)
  end

  label def wait_current
    if Semaphore.where(strand_id: current, name: semaphore).empty? &&
        (!wait_label.is_a?(String) || !(st = Strand[current]) || st.label == wait_label)
      completed << current
      # Also handles completed modifications due to strand.modified!(:stack)
      self.current = nil
      hop_start
    end

    nap((gap / 10).clamp(5, 300))
  end

  label def destroy
    when_destroy_set? do
      pop("rollout completed")
    end

    nap(60 * 60 * 24 * 365)
  end
end
