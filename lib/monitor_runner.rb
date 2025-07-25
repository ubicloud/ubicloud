# frozen_string_literal: true

class MonitorRunner
  def initialize(monitor_resources:, metric_export_resources:, repartitioner:, ignore_threads: 0,
    scan_every: 60, report_every: 5, enqueue_every: 5, check_stuck_pulses_every: 5)
    @monitor_resources = monitor_resources
    @metric_export_resources = metric_export_resources
    @resource_types = [monitor_resources, metric_export_resources].freeze
    @repartitioner = repartitioner
    @internal_threads = @resource_types.sum { it.threads.size } + ignore_threads
    @wakeup_queue = Queue.new
    @shutdown = false

    # The number of seconds until we should run the next scan query. This runs a scan
    # every minute.
    @scan_every = scan_every

    # The number of seconds between reporting monitor metrics.
    @report_every = report_every

    # The number of seconds after a monitor job completes before resubmitting it.
    @enqueue_every = enqueue_every

    # The number of seconds between checking for for stuck pulses.
    @check_stuck_pulses_every = check_stuck_pulses_every
  end

  def shutdown!
    @shutdown = true
    @wakeup_queue.close
    @resource_types.each(&:shutdown!)
  end

  def wait_cleanup!(seconds = nil)
    shutdown!
    @resource_types.each { it.wait_cleanup!(seconds) }
  end

  def scan
    id_range = @repartitioner.strand_id_range

    @resource_types.each do |resource_type|
      queue = resource_type.submit_queue

      # Immediately enqueue new resources
      resource_type.scan(id_range).each { queue.push(it) }
    end
  end

  def emit_metrics
    Clog.emit("monitor metrics") do
      {
        monitor_metrics: {
          active_threads_count: Thread.list.count - @internal_threads,
          threads_waiting_for_db_connection: DB.pool.num_waiting,
          total_monitor_resources: @monitor_resources.resources.size,
          total_metric_export_resources: @metric_export_resources.resources.size,
          monitor_submit_queue_length: @monitor_resources.submit_queue.length,
          metric_export_submit_queue_length: @metric_export_resources.submit_queue.length,
          monitor_idle_worker_threads: @monitor_resources.submit_queue.num_waiting,
          metric_export_idle_worker_threads: @metric_export_resources.submit_queue.num_waiting
        }
      }
    end
  end

  def check_stuck_pulses
    @resource_types.each(&:check_stuck_pulses)
  end

  def enqueue
    # We want to run all jobs that finished more than the given number
    # of seconds ago.
    before = Time.now - @enqueue_every

    # Enqueue resources that finished more than the expected number
    # of seconds ago. This returns the last finish time of the next
    # job to run for each resource type.
    last_finish_times = @resource_types.map { it.enqueue(before) }

    # The resource type may have no jobs to run currently, so remove
    # any nil values.
    last_finish_times.compact!

    # Determine how long to sleep. In general, sleep until it is time
    # to run the next job. If there are no jobs in either run queue,
    # sleep for the maximum amount of time.
    if (last_finish_time = last_finish_times.min)
      (last_finish_time + @enqueue_every) - Time.now
    else
      @enqueue_every
    end
  end

  def run
    # Time after which to run the scan query to check for new resources.
    scan_after = Time.now

    # Time after which to report the number of active threads and other metric information.
    report_after = Time.now + @report_every

    # Time after which to report the number of active threads.
    check_stuck_pulses_after = Time.now + @check_stuck_pulses_every

    until @shutdown
      t = Time.now

      # If the time since last scan has exceeded the deadline, or we
      # have repartitioned since the last iteration, scan again to get the
      # current set of resources for both resource types.
      if t > scan_after || @repartitioner.repartitioned
        scan_after = t + @scan_every
        @repartitioner.repartitioned = false

        scan

        # Pushing to the queue may block, and there may a large amount of time
        # since the last Time.now call.
        t = Time.now
      end

      # If the time since the last report has exceeded the deadline, report again.
      if t > report_after
        report_after = t + @report_every
        emit_metrics
      end

      # If the time since the last pulse check has exceeded the deadline,
      # check again for stuck pulses.
      if t > check_stuck_pulses_after
        check_stuck_pulses_after = t + @check_stuck_pulses_every
        check_stuck_pulses
      end

      sleep_time = enqueue

      # Sleep for the given number of seconds. This uses a timed pop on
      # a queue so that it will exit immediately on shutdown
      @wakeup_queue.pop(timeout: sleep_time)
    end
  rescue ClosedQueueError
    # Shouldn't hit this block unless we are already shutting down,
    # but better to be safe and handle case where we aren't already
    # shutting down, otherwise joining the threads will block.
    shutdown! unless @shutdown
    nil
  rescue => ex
    Clog.emit("Pulse checking or resource scanning has failed.") { {pulse_checking_or_resource_scanning_failure: {exception: Util.exception_to_hash(ex)}} }
    ThreadPrinter.run
    Kernel.exit! 2
  end
end
