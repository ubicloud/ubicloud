# frozen_string_literal: true

# Class that abstracts both monitored resources and metric export resources, to avoid
# duplication for the two types. Attributes:
# wrapper_class :: Either MonitorableResource or MetricsTargetResource
# resources :: Hash of resources, keyed by id
# types :: The underlying model classes (or datasets) to handle
# submit_queue :: A sized queue for submitting jobs for processing. Pushed to by the main thread,
#                 popped by worker threads.
# finish_queue :: A queue for jobs that just finished processing. Pushed to by the
#                 worker threads, popped by the main thread.
# run_queue :: An array keeping track of future jobs to run. The main thread appends jobs
#              popped from the finish queue to this array, and slices the front of the
#              and pushes those jobs to the submit queue.
# threads :: Pool/array of worker threads, which process jobs on the submit queue.
# stuck_pulse_info :: Array with timeout seconds, log message, and log key for handling stuck
#                     pulses/metric exports.
MonitorResourceType = Struct.new(:wrapper_class, :resources, :types, :host_attached_types, :submit_queue, :finish_queue, :run_queue, :threads, :stuck_pulse_info) do
  # Helper method for creating the instance
  def self.create(klass, stuck_pulse_info, num_threads, types, host_attached_types: [])
    pool_size = (num_threads - 2).clamp(1, nil)

    # This does not get updated during runtime, which means that if many resources are
    # added after startup, it may not be sized appropriately.  However, this seems
    # unlikely to matter in practice.
    queue_size = pool_size + (types.sum(&:count) * 1.5).round

    submit_queue = SizedQueue.new(queue_size)
    finish_queue = Queue.new

    threads = Array.new(pool_size) do
      Thread.new do
        while (r = submit_queue.pop)
          begin
            # We keep track of started at information to check for stuck pulses.
            r.monitor_job_started_at = Time.now
            r.open_resource_session

            # Yield so that monitored resources and metric export resources can be
            # handled differently.
            yield r
          rescue Sequel::DatabaseDisconnectError, Sequel::DatabaseConnectionError
            # Reraise so that ensure block runs without checkup being incremented,
            # and the outer rescue retries.
            raise
          rescue => ex
            Clog.emit("Monitoring job has failed.", {monitoring_job_failure: Util.exception_to_hash(ex, into: {resource: r.resource})})
            r.resource.incr_checkup if r.resource.respond_to?(:incr_checkup) && !r.resource.checkup_set?
          ensure
            # We unset the started at time so we will not check for stuck pulses
            # while this is in the run queue.
            r.monitor_job_started_at = nil

            # We record the finish time before pushing to the queue to allow for
            # more accurate scheduling.
            r.monitor_job_finished_at = Time.now
            finish_queue.push(r)
          end
        end
      rescue Sequel::DatabaseDisconnectError, Sequel::DatabaseConnectionError
        sleep(1 + rand)
        retry
      rescue => ex
        Clog.emit("unexpected monitor worker thread error", {monitor_worker_thread_error: Util.exception_to_hash(ex, into: {resource: r.resource})})
        raise
      end
    end

    new(klass, {}, types, host_attached_types, submit_queue, finish_queue, [], threads, stuck_pulse_info)
  end

  def shutdown!
    submit_queue.close
  end

  def wait_cleanup!(seconds = nil)
    shutdown!
    threads.each { it.join(seconds) }
  end

  # Check each resource for stuck pulses/metric exports, and log if any are found.
  def check_stuck_pulses
    timeout, msg, key = stuck_pulse_info
    t = Time.now
    before = t - timeout
    resources.each_value do |r|
      if r.monitor_job_started_at&.<(before)
        Clog.emit(msg, {
          key => {
            ubid: r.resource.ubid,
            job_started_at: r.monitor_job_started_at,
            time_elapsed: t - r.monitor_job_started_at
          }
        })
      end
    end
  end

  # Update the resources the instance will monitor/metric export. If the resource
  # to be monitored was previously monitored, keep the previous version, as it will
  # likely have an ssh session already setup. Returns the newly scanned resources,
  # which will be the next ones to process.
  def scan(id_range)
    scanned_resources = {}
    new_resources = []
    hosts = {} unless host_attached_types.empty?

    types.each do |type|
      populate_hosts = hosts && type == VmHost

      type.where_each(id: id_range) do
        unless (v = resources[it.id])
          v = wrapper_class.new(it)
          new_resources << v
        end
        scanned_resources[it.id] = v
        hosts[it.id] = v if populate_hosts
      end
    end

    unless host_attached_types.empty?
      hash = {}

      host_attached_types.each do |ds|
        ds.where(vm_host_id: id_range).to_hash_groups(:vm_host_id, nil, hash:)
      end

      hash.each do |vm_host_id, vms|
        if (host = hosts.delete(vm_host_id))
          new_attached_resources = {}
          old_attached_resources = host.attached_resources
          vms.each do
            new_attached_resources[it.id] = old_attached_resources[it.id] || wrapper_class.new(it)
          end
          host.attached_resources.replace(new_attached_resources)
        end
      end

      # These are hosts who may have had attached resources in earlier scans,
      # but did not have any attached resources in the current scan.
      hosts.each_value do
        it.attached_resources.clear
      end
    end

    self.resources = scanned_resources
    new_resources
  end

  # Update the run_queue with jobs that have finished. Then enqueue each resource
  # if it finished before the given time. Enqueued resources will be processed by
  # the worker thread pool.
  def enqueue(before)
    # Pop all available jobs out of the finish queue and add them to the
    # run queue. This can result in jobs that a very slightly out of order,
    # due to thread scheduling, but the differences are not likely to be material.
    while (r = finish_queue.pop(timeout: 0))
      if r.deleted
        resources.delete(r.resource.id)
      else
        run_queue << r
      end
    end

    unless run_queue.empty?
      # Find first job in run queue that shouldn't be submitted.
      #
      # Slice the jobs before that in the run queue, which should be submitted,
      # from the front of the run queue.
      #
      # If the first job in the run queue shouldn't be submitted, this ends
      # up not slicing anything off the run queue.
      #
      # If all jobs should be submitted, then this slices all jobs off the
      # run queue.
      i = run_queue.find_index { it.monitor_job_finished_at > before } || run_queue.size
      run_queue.slice!(0, i).each do
        # If the job in the run queue is no longer a monitored resource,
        # then don't add it to the submit queue. This ensures we don't
        # continue to monitor a resource after it has been deleted or is
        # no longer in the current partition.
        submit_queue.push(it) if resources[it.resource.id]
      end
      run_queue[0]&.monitor_job_finished_at
    end
  end
end
