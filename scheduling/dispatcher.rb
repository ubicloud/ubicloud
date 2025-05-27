# frozen_string_literal: true

# Scheduling::Dispatcher is used for running strands. It finds strands
# that should be run, and runs them using a thread pool. It keeps a
# record of which strands are currently being processed, so that it
# does not retrieve them.
class Scheduling::Dispatcher
  attr_reader :shutting_down

  STRAND_RUNTIME = Strand::LEASE_EXPIRATION / 4
  APOPTOSIS_MUTEX = Mutex.new

  def initialize(apoptosis_timeout: Strand::LEASE_EXPIRATION - 29)
    @shutting_down = false

    # How long to wait in seconds from the start of strand run
    # for the strand to finish until killing the process.
    @apoptosis_timeout = apoptosis_timeout

    # Hash of currently executing strands.  This can be accessed by
    # multiple threads concurrently, so access is protected via a mutex.
    @current_strands = {}
    # Mutex for current strands
    @mutex = Mutex.new

    # The thread pool size.  Set to one less than the number of database
    # connections, to ensure there is a connection always available for the
    # main thread, for the query to find strands to run.
    pool_size = Config.db_pool - 1

    # The Queue that all threads in the thread pool pull from.  This is a
    # SizedQueue to allow for backoff in the case that the thread pool cannot
    # process jobs fast enough. When the queue is full, the main thread to
    # push strands into the queue blocks until the queue is no longer full.
    # The queue size is 4 times the size of the thread pool, as that should
    # ensure that for a busy thread pool, there are always strands to run.
    # This should only cause issues if the thread pool can process more than
    # 4 times its size in the time it takes the main thread to refill the queue.
    @strand_queue = SizedQueue.new(pool_size * 4)

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

    # A prepared statement to get the strands to run.  A prepared statement
    # is used to reduce parsing/planning work in the database.
    @strand_ps = Strand
      .where(
        Sequel.|({lease: nil}, Sequel[:lease] < Sequel::CURRENT_TIMESTAMP) &
        (Sequel[:schedule] < Sequel::CURRENT_TIMESTAMP) &
        {exitval: nil}
      )
      .order_by(:schedule)
      .limit(pool_size)
      .exclude(id: Sequel.function(:ANY, Sequel.cast(:$skip_strands, "uuid[]")))
      .prepare(:select, :get_strand_cohort)
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
    @thread_data.each { @strand_queue.push(nil) }

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
      strand_thread: Thread.new { strand_thread(strand_queue, start_queue, finish_queue) }
    }
  end

  # If the process is shutting down, return an empty array.  Otherwise
  # call the database prepared statement to find the strands to run,
  # excluding the strands that are currently running in the thread pool.
  def scan
    @shutting_down ? [] : @strand_ps.call(skip_strands: Sequel.pg_array(@mutex.synchronize { @current_strands.keys }))
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
      Kernel.exit!
    end
  end

  # The entry point for strand threads.  The loops until the
  # dispatcher shuts down, monitoring the strand queue, signalling
  # the related apoptosis thread when starting, running the strand,
  # and then signalling the related apoptosis thread when the
  # strand run finishes.
  def strand_thread(strand_queue, start_queue, finish_queue)
    run_strand(strand_queue.pop, start_queue, finish_queue) until @shutting_down
  ensure
    # Signal related apoptosis thread to shutdown
    start_queue.push(nil)
  end

  # Handle the running of a single strand.  Signals the apoptosis
  # thread via the start queue when starting, and the finish queue
  # when exiting.
  def run_strand(strand, start_queue, finish_queue)
    # Shutdown indicated, return immediately
    return unless strand

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
    @mutex.synchronize { @current_strands.delete(strand&.id) }
  end

  # Find strands that need to be run, and push each onto the
  # strand queue.  This can block if the strand queue is full,
  # to allow for backoff in the case of a busy thread pool.
  def start_cohort
    strand_queue = @strand_queue
    current_strands = @current_strands
    strands = scan
    strands.each do |strand|
      break if @shutting_down
      @mutex.synchronize { current_strands[strand.id] = true }
      strand_queue.push(strand)
    end

    strands.size == 0
  end
end
