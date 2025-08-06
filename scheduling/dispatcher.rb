# frozen_string_literal: true

# Scheduling::Dispatcher is used for running strands. It finds strands
# that should be run, and runs them using a thread pool. It keeps a
# record of which strands are currently being processed, so that it
# does not retrieve them.
class Scheduling::Dispatcher
  attr_reader :shutting_down

  STRAND_RUNTIME = Strand::LEASE_EXPIRATION / 4
  APOPTOSIS_MUTEX = Mutex.new

  class Repartitioner < ::Repartitioner
    def initialize(dispatcher:, **)
      @dispatcher = dispatcher
      super(**)
    end

    # Update the dispatcher prepared statement when repartitioning.
    def repartition(num_partitions)
      super
      @dispatcher.setup_prepared_statements(strand_id_range:)
    end
  end

  # Arguments:
  # apoptosis_timeout :: The number of seconds a strand is allowed to
  #                      run before causing apoptosis.
  # listen_timeout :: The number of seconds to wait for a single notification
  #                   when listening.  Only has an effect when the process uses
  #                   partitioning. Generally only changed in the tests to make
  #                   shutdown faster.
  # pool_size :: The number of threads in the thread pool.
  # partition_number :: The partition number of the current respirate process. A nil
  #                     value means the process does not use partitioning.
  def initialize(apoptosis_timeout: Strand::LEASE_EXPIRATION - 29, pool_size: Config.dispatcher_max_threads, partition_number: nil, listen_timeout: 1)
    @shutting_down = false

    # How long to wait in seconds from the start of strand run
    # for the strand to finish until killing the process.
    @apoptosis_timeout = apoptosis_timeout

    # Hash of currently executing strands.  This can be accessed by
    # multiple threads concurrently, so access is protected via a mutex.
    @current_strands = {}
    # Mutex for current strands
    @mutex = Mutex.new

    # Set configured limits on pool size. This will raise if the maximum number
    # of threads is lower than the minimum.
    pool_size = pool_size.clamp(Config.dispatcher_min_threads, Config.dispatcher_max_threads)

    needed_db_connections = 1
    needed_db_connections += 1 if partition_number
    # Ensure thread pool size is sane.  It needs to be at least 1, we cannot
    # use more threads than database connections (db_pool - 1), and we need
    # separate database connections for the scan thread and the repartition
    # thread.
    pool_size = pool_size.clamp(1, Config.db_pool - 1 - needed_db_connections)

    # The queue size is 4 times the size of the thread pool by default, as that should
    # ensure that for a busy thread pool, there are always strands to run.
    # This should only cause issues if the thread pool can process more than
    # 4 times its size in the time it takes the main thread to refill the queue.
    @queue_size = (pool_size * Config.dispatcher_queue_size_ratio).round.clamp(1, nil)

    # The Queue that all threads in the thread pool pull from.  This is a
    # SizedQueue to allow for backoff in the case that the thread pool cannot
    # process jobs fast enough. When the queue is full, the main thread to
    # push strands into the queue blocks until the queue is no longer full.
    @strand_queue = SizedQueue.new(@queue_size)

    # An array of thread pool data.  This starts pool_size * 2 threads.  Half
    # of the threads are strand threads, responsible for running the strands.
    # The other half are apoptosis threads, each responsible for monitoring
    # the related strand thread.  The strand thread notifies the apoptosis
    # thread via a queue when it starts, and also when it finishes.  If a
    # strand thread does not notify the apoptosis thread of it finishing
    # before the apoptosis timeout, then the process exits.
    @thread_data = Array.new(pool_size) do
      start_thread_pair(@strand_queue)
    end

    # The Queue for submitting metrics.  This is pushed to for each strand run.
    @metrics_queue = Queue.new

    # The thread that processes the metrics queue and emits metrics.
    @metrics_thread = Thread.new { metrics_thread(@metrics_queue) }

    # The partition number for the current process.
    @partition_number = partition_number

    # The partition number as a string, used in NOTIFY statements.
    @partition_number_string = partition_number.to_s

    # How long to wait for each NOTIFY. By default, this is 1 second, to
    # ensure that heartbeat NOTIFY for the current process and possible
    # rebalancing takes place about once every second.
    @listen_timeout = listen_timeout

    # The delay experienced for strands for this partition. Stays at 0 for
    # an unpartitioned respirate.  Partitioned respirate will update this
    # every time it emits metrics, so that if it is backed up processing
    # current strands, it assumes other respirate processes are also backed
    # up, and will not pick up their strands for an additional time.
    @current_strand_delay = 0

    # Default number of strands per second. This will be updated based on
    # based on metrics. Used for calculating the sleep duration.
    @strands_per_second = 1

    if partition_number
      # Handles repartitioning when new partitions show up or old partitions
      # go stale.
      @repartitioner = Repartitioner.new(partition_number:, channel: :respirate,
        max_partition: 256, dispatcher: self, listen_timeout:,
        recheck_seconds: listen_timeout * 2, stale_seconds: listen_timeout * 4)

      # The thread that listens for changes in the number of respirate processes
      # and adjusts the partition range accordingly.
      @repartition_thread = Thread.new { @repartitioner.listen }
    else
      # Setup an unpartitioned prepared statement.
      # This method is called implicitly with the appropriate partition when
      # initializing the repartitioner in the if branch.
      setup_prepared_statements(strand_id_range: nil)
    end
  end

  # Wait for all threads to exit after shutdown is set.
  # Designed for use in the tests.
  def shutdown_and_cleanup_threads
    # Make idempotent
    return if @cleaned_up

    shutdown

    @cleaned_up = true

    # Signal all threads to shutdown. This isn't done by
    # default in shutdown as pushing to the queue can block.
    # We use SizedQueue#close here to allow shutdown to proceed
    # even if the scan thread is blocked on pushing to the queue
    # and all strand threads are busy processing strands.
    @strand_queue.close

    # Close down the metrics processing. This pushes nil to the
    # metrics_queue instead of using close, avoiding the need
    # to rescue ClosedQueueError in the run_strand ensure block.
    @metrics_queue.push(nil)
    @metrics_thread.join

    # Close down the repartition thread if is exists.  Note that
    # this can block for up to a second.
    @repartition_thread&.join

    # After all queues have been pushed to, it is safe to
    # attempt joining them.
    @thread_data.each do |data|
      data[:apoptosis_thread].join
      data[:strand_thread].join
    end
  end

  # Signal that the dispatcher should shut down.  This only sets a flag.
  # Strand threads will continue running their current thread, and
  # apoptosis threads will continue running until after their related
  # strand thread signals them to exit.
  def shutdown
    @shutting_down = true
    @repartitioner&.shutdown!
  end

  def setup_prepared_statements(strand_id_range:)
    # A prepared statement to get the strands to run.  A prepared statement
    # is used to reduce parsing/planning work in the database.
    ds = Strand
      .where(Sequel[:lease] < Sequel::CURRENT_TIMESTAMP)
      .where(exitval: nil)
      .order_by(:schedule)
      .limit(@queue_size)
      .exclude(id: Sequel.function(:ANY, Sequel.cast(:$skip_strands, "uuid[]")))
      .select(:id, :schedule, :lease)
      .for_no_key_update
      .skip_locked

    # If a partition is given, limit the strands to the partition.
    # Create a separate prepared statement for older strands, not tied to
    # the current partition, to allow for graceful degradation.
    if strand_id_range
      # The old strand prepared statement does not change based on the
      # number of partitions, so no reason to reprepare it.
      @old_strand_ps ||= ds
        .where(Sequel[:schedule] < Sequel::CURRENT_TIMESTAMP - Sequel.cast(Sequel.cast(:$old_strand_delay, String) + " seconds", :interval))
        .prepare(:select, :get_old_strand_cohort)

      ds = ds.where(id: strand_id_range)
      Clog.emit("respirate repartitioning") { {partition: strand_id_range} }
    else
      @old_strand_ps = nil
    end

    @strand_ps = ds
      .where(Sequel[:schedule] < Sequel::CURRENT_TIMESTAMP)
      .prepare(:select, :get_strand_cohort)
  end

  # Thread responsible for collecting and emitting metrics. This emits after every
  # 1000 strand runs, as that allows easy calculations of the related metrics and is
  # not too to burdensome on the logging infrastructure, while still being helpful.
  def metrics_thread(metrics_queue)
    array = []
    t = Time.now
    while (metric = metrics_queue.pop)
      array << metric
      if array.size == METRICS_EVERY
        new_t = Time.now
        Clog.emit("respirate metrics") { {respirate_metrics: metrics_hash(array, new_t - t)} }
        t = new_t
        array.clear
      end
    end
  end

  METRIC_TYPES = %i[scan_delay queue_delay lease_delay total_delay queue_size available_workers].freeze

  # The batch size for metrics output.  Mezmo batches their real time graph in 30 second
  # intervals, and a batch size of 1000 meant that there would be intervals where Mezmo
  # would see no results.  Even when it saw results, the results would be choppy. By
  # outputing more frequently, we should get smoother and more accurate graphs.
  METRICS_EVERY = 200

  # Calculate the necessary offsets up front for the median/p75/p85/p95/p99 numbers,
  # and the multiplier to get the lease acquired percentage.
  METRICS_MEDIAN = (METRICS_EVERY * 0.5r).floor
  METRICS_P75 = (METRICS_EVERY * 0.75r).floor
  METRICS_P85 = (METRICS_EVERY * 0.85r).floor
  METRICS_P95 = (METRICS_EVERY * 0.95r).floor
  METRICS_P99 = (METRICS_EVERY * 0.99r).floor
  METRICS_PERCENTAGE = 100.0 / METRICS_EVERY

  # Metrics to emit.  This assumes an array size of 1000.  The following metrics are emitted:
  #
  # Strand delay metrics:
  #
  # scan_delay :: Time between when the strand was scheduled, and when the scan query
  #               picked the strand up.
  # queue_delay :: Time between when the scan query picked up the strand, and when a
  #                worker thread started working on the strand.
  # lease_delay :: Time between when a worker thread started working on the strand, and
  #                when it acquired (or failed to acquire) the strand's lease.
  #
  # Respirate internals metrics:
  #
  # queue_size :: The size of the strand queue after the worker thread picked up the strand.
  #               This is the backlog of strands waiting to be processed.
  # available_workers :: The number of idle worker threads that are waiting to work on strands.
  #                      There should only be an idle worker if the queue size is currently 0.
  #
  # For the above metrics, we compute the average, median, P75, P85, P95, P99, and maximum
  # values.
  #
  # In addition to the above metrics, there are additional metrics:
  #
  # lease_acquire_percentage :: Percentage of strands where the lease was successfully acquired.
  #                             For single respirate processes, or normally running respirate
  #                             partitioned processes (1 process per partition), this should be
  #                             100.0. For multi-process, non-partitioned respirate, this can
  #                             be significantly lower, as multiple processes try to process
  #                             the same strand concurrently, and some fail to acquire the lease.
  # old_strand_percentage :: Percentage of strands that were processed that were outside the
  #                          current partition.  Should always be 0 if respirate is not partitioned.
  def metrics_hash(array, elapsed_time)
    respirate_metrics = {}
    METRIC_TYPES.each do |metric_type|
      metrics = array.map(&metric_type)
      metrics.sort!
      average = metrics.sum / METRICS_EVERY
      median = metrics[METRICS_MEDIAN]
      p75 = metrics[METRICS_P75]
      p85 = metrics[METRICS_P85]
      p95 = metrics[METRICS_P95]
      p99 = metrics[METRICS_P99]
      max = metrics.last
      respirate_metrics[metric_type] = {average:, median:, p75:, p85:, p95:, p99:, max:}
    end
    respirate_metrics[:lease_acquire_percentage] = array.count(&:lease_acquired) * METRICS_PERCENTAGE
    respirate_metrics[:old_strand_percentage] = array.count(&:old_strand) * METRICS_PERCENTAGE
    respirate_metrics[:lease_expired_percentage] = array.count(&:lease_expired) * METRICS_PERCENTAGE
    respirate_metrics[:strand_count] = METRICS_EVERY
    @strands_per_second = METRICS_EVERY / elapsed_time
    respirate_metrics[:strands_per_second] = @strands_per_second

    # Use the p95 of total delay to set the delay for the current strands.
    # Ignore the delay for old strands when calculating delay for current strands.
    # Using the maximum/p99 numbers may cause too long delay if there are
    # outliers.  Using lower numbers (e.g. median/p75) may not accurately reflect the
    # current delay numbers if the delay is increasing rapidly.
    array.reject!(&:old_strand)
    array.map!(&:total_delay)
    respirate_metrics[:current_strand_delay] = @current_strand_delay = array[(array.count * 0.95r).floor] || 0

    respirate_metrics
  end

  # The amount of time to sleep if no strands or old strands were picked up
  # during the last scan loop.
  def sleep_duration
    # Set base sleep duration based on on queue size and the number of strands processed
    # per second.  If you are processing 10 strands per second, and there are 5 strands
    # in the queue, it should take about 0.5 seconds to get through the existing strands.
    # Multiply by 0.75, since @strands_per_second is only updated occassionally by
    # the metrics thread.
    sleep_duration = ((@strand_queue.size * 0.75) / @strands_per_second)

    # You don't want to query the database too often, especially when the queue is empty
    # and respirate is idle.  Estimate how idle the respirate process is by looking at
    # the percentage of available workers, and use that as a lower bound. If you have
    # 6 available workers and 8 total workers, that's close to idle, set a minimum
    # sleep time of 0.75 seconds.  If you have 2 available workers and 8 total workers,
    # that's pretty busy, set a minimum sleep time of 0.25 seconds.
    available_workers = @strand_queue.num_waiting
    workers = @thread_data.size
    sleep_duration = sleep_duration.clamp(available_workers.fdiv(workers), nil)

    # Finally, set asbolute minimum sleep time to 0.2 seconds, to not overload the
    # database, and set absolute maximum sleep time to 1 second, to not wait too long
    # to pick up strands.
    sleep_duration.clamp(0.2, 1)
  end

  # Start a strand/apoptosis thread pair, where the strand thread will
  # pull from the given strand queue.
  #
  # On strand run start:
  #
  # * The strand thread pushes the strand ubid to the start queue,
  #   and the apoptosis thread pops it and starts a timed pop on the
  #   finish queue.
  #
  # On strand run finish:
  #
  # * The strand thread pushes to the finish queue to signal to the
  #   apoptosis thread that it is finished.  The strand goes back
  #   to monitoring the strand queue, and the apoptosis thread goes
  #   back to monitoring the start queue.
  #
  # On strand run timeout:
  #
  # * If the timed pop of the finish queue by the apoptosis thread
  #   does not complete in time, the apoptosis thread kills the process.
  def start_thread_pair(strand_queue)
    start_queue = Queue.new
    finish_queue = Queue.new
    {
      start_queue:,
      finish_queue:,
      apoptosis_thread: Thread.new { apoptosis_thread(start_queue, finish_queue) },
      strand_thread: Thread.new { DB.synchronize { strand_thread(strand_queue, start_queue, finish_queue) } }
    }
  end

  # If the process is shutting down, return an empty array.  Otherwise
  # call the database prepared statement to find the strands to run,
  # excluding the strands that are currently running in the thread pool.
  # If respirate processes are partitioned, this will only return
  # strands for the current partition.
  def scan
    @shutting_down ? [] : @strand_ps.call(skip_strands:).each(&:scan_picked_up!)
  end

  # Similar to scan, but return older strands which may not be
  # related to the current partition.  This is to allow for
  # graceful degradation if a partitioned respirate process
  # crashes or experiences apoptosis.
  def scan_old
    unless @shutting_down
      @old_strand_ps&.call(skip_strands:, old_strand_delay:)&.each(&:scan_picked_up!)&.each(&:old_strand!)
    end || []
  end

  # The number of seconds to wait before picking up strands from
  # outside the current partition.  This uses how long it is
  # taking to process strands in the current partition, adds 20%
  # to that, then adds an additional 5 seconds.  The reason for
  # 20% is the current strand delay is only recalculated every
  # METRICS_EVERY, so this allows some padding in case the delay
  # number is growing quickly.
  def old_strand_delay
    (@current_strand_delay * 1.2) + 5
  end

  # A pg_array for the strand ids to skip.  These are the strand
  # ids that have been enqueued or are currently being processed
  # by strand threads.
  def skip_strands
    Sequel.pg_array(@mutex.synchronize { @current_strands.keys })
  end

  # The number of strands the thread pool is currently running.
  def num_current_strands
    @mutex.synchronize { @current_strands.size }
  end

  # The entry point for apoptosis threads.  This loops until the
  # dispatcher shuts down, monitoring the start queue, and once
  # signaled via the start queue, kills the process unless it is
  # signaled via the finish queue within the apoptosis timeout.
  def apoptosis_thread(start_queue, finish_queue)
    timeout = @apoptosis_timeout
    until @shutting_down
      break unless apoptosis_run(timeout, start_queue, finish_queue)
    end
  rescue
    apoptosis_failure
  end

  # Performs a single apoptosis run.  Waits until signaled by the
  # start queue, then does a timed pop of the finish queue, killing
  # the process if the pop times out.
  def apoptosis_run(timeout, start_queue, finish_queue)
    return unless (strand_ubid = start_queue.pop)
    Thread.current.name = "apoptosis:#{strand_ubid}"
    unless finish_queue.pop(timeout:)
      apoptosis_failure
    end
    true
  end

  # Handle timeout of a strand thread by killing the process.
  def apoptosis_failure
    # Timed out, dump threads and exit.
    # Don't thread print concurrently.
    APOPTOSIS_MUTEX.synchronize do
      ThreadPrinter.run
      Kernel.exit! 2
    end
  end

  # The entry point for strand threads.  The loops until the
  # dispatcher shuts down, monitoring the strand queue, signalling
  # the related apoptosis thread when starting, running the strand,
  # and then signalling the related apoptosis thread when the
  # strand run finishes.
  def strand_thread(strand_queue, start_queue, finish_queue)
    while (strand = strand_queue.pop) && !@shutting_down
      strand.worker_started!
      metrics = strand.respirate_metrics
      metrics.queue_size = strand_queue.size
      metrics.available_workers = strand_queue.num_waiting
      run_strand(strand, start_queue, finish_queue)
    end
  ensure
    # Signal related apoptosis thread to shutdown
    start_queue.push(nil)
  end

  # Handle the running of a single strand.  Signals the apoptosis
  # thread via the start queue when starting, and the finish queue
  # when exiting.
  def run_strand(strand, start_queue, finish_queue)
    strand_ubid = strand.ubid.freeze
    Thread.current.name = strand_ubid
    start_queue.push(strand_ubid)
    strand.run(STRAND_RUNTIME)
  rescue => ex
    Clog.emit("exception terminates strand run") { Util.exception_to_hash(ex) }

    cause = ex
    loop do
      break unless (cause = cause.cause)
      Clog.emit("nested exception") { Util.exception_to_hash(cause) }
    end
    ex
  ensure
    # Always signal apoptosis thread that the strand has finished,
    # even for non-StandardError exits
    finish_queue.push(true)
    @mutex.synchronize { @current_strands.delete(strand.id) }

    @metrics_queue.push(strand.respirate_metrics)

    # If there are any sessions in the thread-local (really fiber-local) ssh
    # cache after the strand run, close them eagerly to close the related
    # file descriptors, then clear the cache to avoid a memory leak.
    if (cache = Thread.current[:clover_ssh_cache]) && !cache.empty?
      cache.each_value do
        # closing the ssh connection shouldn't raise, but just in case it
        # does, we want to ignore it so the strand thread doesn't exit.
        it.close
      rescue
      end
      cache.clear
    end
  end

  # Find strands that need to be run, and push each onto the
  # strand queue.  This can block if the strand queue is full,
  # to allow for backoff in the case of a busy thread pool.
  def start_cohort(strands = scan)
    strand_queue = @strand_queue
    current_strands = @current_strands
    strands.each do |strand|
      break if @shutting_down
      @mutex.synchronize { current_strands[strand.id] = true }
      strand_queue.push(strand)
    rescue ClosedQueueError
    end

    strands.size == 0
  end
end
