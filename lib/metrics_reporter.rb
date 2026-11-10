# frozen_string_literal: true

require "socket"

# Reports a metrics registry to VictoriaMetrics on a fixed interval, from a
# thread started by the owning process.
class MetricsReporter
  # Direct access to the shutdown queue. Only designed for use by the tests.
  attr_reader :shutdown_queue

  def initialize(name:, metrics:, interval: 15, instance: ENV["DYNO"] || Socket.gethostname)
    @metrics = metrics
    @name = name
    @interval = interval
    @extra_labels = {instance:}.freeze
    @shutdown_queue = Queue.new
    @thread = nil
    @shutdown = false
  end

  # Stop the report loop and shutdown its thread, if it is running.
  def shutdown!
    # Make method idempotent
    return if @shutdown

    @shutdown = true
    @shutdown_queue.push(true)
    @thread&.join

    nil
  end

  # Start a thread that runs the run method. This thread will generally run
  # until shutdown! is called.
  def run_thread
    @thread = Thread.new do
      run
      true
    rescue => e
      Clog.emit("#{@name} metrics reporter thread exiting due to unexpected error", Util.exception_to_hash(e))
      false
    end
  end

  # Report once per interval until shutdown! is called.
  def run
    until @shutdown_queue.pop(timeout: @interval)
      report
    end
  end

  def report
    unless (client = VictoriaMetricsResource.client_for_project(Config.victoria_metrics_service_project_id))
      Clog.emit("#{@name} metrics report skipped because VictoriaMetrics is not configured")
      return
    end

    client.import_prometheus(VictoriaMetrics::Client::Scrape.new(time: Time.now, samples: @metrics.render), @extra_labels)
  rescue VictoriaMetrics::ClientError, Sequel::Error => e
    # Sequel included: the client lookup queries the database.
    Clog.emit("#{@name} metrics report failed", Util.exception_to_hash(e))
  end
end
