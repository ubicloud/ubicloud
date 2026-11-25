# frozen_string_literal: true

require "time"

# This runs in the Puma master process, and handles restarting worker
# processes on a time basis, to limit worker process memory usage.
class PumaWorkerRefresher
  # Direct access to the shutdown queue. Only designed for use by the tests.
  attr_reader :shutdown_queue

  def self.run
    if (web_concurrency = ENV["WEB_CONCURRENCY"]) &&
        (num_workers = Integer(web_concurrency, 10, exception: false)) &&
        (num_workers > 0) &&
        (dyno = ENV["DYNO"] || ENV["PS"]) &&
        (match = /\Aweb\.(\d+)\z/.match(dyno))

      interval = (Config.puma_worker_refresh_deadline * 60) / num_workers
      initial_sleep = Integer(match[1], 10) * 60
      refresher = new(initial_sleep:, interval:)
      refresher.run_thread
      refresher
    end
  end

  def initialize(interval:, initial_sleep: 0, get_stats: Puma.method(:stats_hash))
    @initial_sleep = initial_sleep
    @interval = interval
    @get_stats = get_stats
    @shutdown_queue = Queue.new
    @thread = nil
    @shutdown = false
  end

  def shutdown!
    return if @shutdown

    @shutdown = true
    @shutdown_queue.push(true)
    @thread&.join

    nil
  end

  def run_thread
    @thread = Thread.new do
      Thread.current.name = "puma_worker_refresher"
      @shutdown_queue.pop(timeout: @initial_sleep)
      run
      true
    rescue => e
      Clog.emit("puma worker refresher thread exiting due to unexpected error", Util.exception_to_hash(e))
      false
    end
  end

  def run
    timeout = @interval
    queue = @shutdown_queue
    retire_oldest_worker until @shutdown || queue.pop(timeout:)
  end

  # Send SIGTERM to the earliest spawned worker, causing that worker to
  # exit after handling its current requests. Puma will restart a worker
  # to replace the exited one. Returns the pid of the retired worker, or
  # nil if no worker was retired.
  def retire_oldest_worker
    return unless (worker = oldest_worker)

    pid = worker[:pid]
    Clog.emit("retiring puma worker", {puma_worker_refresher: {pid:, index: worker[:index], started_at: worker[:started_at]}})
    Process.kill(:TERM, pid)
    pid
  rescue Errno::ESRCH
    # Worker already exited, Puma will spawn a replacement.
    nil
  end

  private

  # The earliest started worker. Workers that have not yet booted are
  # ignored, as they were recently spawned. Workers that started in the
  # same second are ordered by worker index.
  def oldest_worker
    @get_stats.call[:worker_status]
      &.select { it[:pid] && it[:booted] }
      &.min_by { [Time.iso8601(it[:started_at]), it[:index]] }
  end
end
