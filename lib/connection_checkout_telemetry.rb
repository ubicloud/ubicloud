# frozen-string-literal: true

class ConnectionCheckoutTelemetry
  class Queue < ::Queue
    # Avoid need to wrap the queues in a proc
    alias_method :call, :push
  end

  # Direct access to the checkout event notification queue. Only designed for use by
  # the tests.
  attr_reader :queue

  # key :: Clog.emit key to use
  # check_every :: the number of connection requests between deciding whether to report
  # report_every :: the minimum number of seconds between reports
  def initialize(db: DB, key: "#{ENV["PROCESS_TYPE"]}_connection_checkout_metrics", check_every: 300, report_every: 20)
    db.extension :connection_checkout_event_callback
    @pool = db.pool
    @key = key
    @check_every = check_every
    @report_every = report_every
    @queue = Queue.new
    @thread = nil
    @shutdown = false
  end

  # Stop processing events on the queue, and shutdown the monitoring thread,
  # if it is running.
  def shutdown!
    # Make method idempotent
    return if @shutdown

    @shutdown = true

    # We would normally replace the checkout event hook:
    #
    #   @pool.on_checkout_event = proc {}
    #
    # However, this isn't possible when running with a frozen database.
    # Since this class is used for the entire runtime of the web, respirate,
    # and monitor processes, and only shuts down when the processes are shutting
    # down, it's fine not to reset the hook.

    # Push nil instead of closing the queue, as there could still be concurrent
    # access to it by other threads during shutdown.
    @queue.push(nil)

    @thread&.join

    nil
  end

  # Start monitoring connection checkout events for the database.
  def setup
    @pool.on_checkout_event = @queue
  end

  # Start a thread that runs the run method. This thread will generally run
  # until shutdown! is called.
  def run_thread
    @thread = Thread.new do
      run
      true
    rescue => e
      Clog.emit("#{@key} failure", Util.exception_to_hash(e))
      false
    end
  end

  # Helper for running both setup and run_thread.
  def setup_and_run_thread
    setup
    run_thread
  end

  # Continually process connection checkout events until shutdown! is called.
  def run
    pool = @pool
    key = @key
    message = key.tr("_", " ").freeze
    check_every = @check_every
    report_every = @report_every
    queue = @queue
    bucket_names = %w[immediate 0_30_ms 30_100_ms 100_300_ms 300_1000_ms 1_3_s over_3_s].freeze

    requests = immediates = waits = 0
    bucket_count = bucket_names.length - 1
    empty_buckups = ([0] * bucket_count).freeze
    buckets = empty_buckups.dup

    # Use separate counter instead of requests % check_every == 0
    i = 0

    last_report = Sequel.start_timer

    while (event = queue.pop)
      case event
      when :immediately_available
        requests += 1
        immediates += 1
      when :not_immediately_available
        requests += 1
      when :new_connection
        immediates += 1
      else # seconds waited for connection
        waits += 1
        time = event

        # Benchmarks faster than a Math.log10 approach
        # Nested conditional for at most 3 comparisons per iteration
        bucket = if time < 0.3
          if time < 0.1
            (time < 0.03) ? 0 : 1
          else
            2
          end
        elsif time < 3
          (time < 1) ? 3 : 4
        else
          5
        end

        buckets[bucket] += 1
      end

      i += 1

      if i == check_every
        i = 0

        if Sequel.elapsed_seconds_since(last_report) > report_every
          last_report = Sequel.start_timer
          # The async nature of metrics reporting means there can be more
          # immediates and waits than connection requests. If that is the case,
          # increase requests so that the sum of percentages never exceeds 100.
          requests = requests.clamp(immediates + waits, nil)
          data = bucket_names.zip([immediates, *buckets]).to_h do |name, values|
            [name, (100.0 * values) / requests]
          end
          data["requests"] = requests
          data["pool_size"] = pool.size
          Clog.emit(message, key => data)

          requests = immediates = waits = 0
          buckets = empty_buckups.dup
        end
      end
    end
  end
end
