# frozen_string_literal: true

require "socket"

# Reports a metrics registry to VictoriaMetrics on a fixed interval, from a
# thread started by the owning process.
class MetricsReporter
  # Direct access to the shutdown queue. Only designed for use by the tests.
  attr_reader :shutdown_queue

  def initialize(name:, metrics:, project_id:, interval: 15, shutdown_timeout: 1, instance: ENV["DYNO"] || Socket.gethostname)
    @metrics = metrics
    @name = name
    @project_id = project_id
    @interval = interval
    @shutdown_timeout = shutdown_timeout
    @extra_labels = {instance:}.freeze
    @shutdown_queue = Queue.new
    @thread = nil
    @shutdown = false
    @report_count = 0
  end

  # Stop the report loop and shutdown its thread, if it is running.
  def shutdown!
    # Make method idempotent
    return if @shutdown

    @shutdown = true
    @shutdown_queue.push(true)
    @thread&.join(@shutdown_timeout)

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

  # Report once per interval until shutdown! is called, then report a final time.
  def run
    until @shutdown_queue.pop(timeout: @interval)
      report
    end
    report
  end

  def report
    start = Time.now
    unless (client = VictoriaMetricsResource.client_for_project(@project_id))
      Clog.emit("#{@name} metrics report skipped because VictoriaMetrics is not configured")
      return
    end

    render_start = Time.now
    samples = @metrics.render
    import_start = Time.now
    client.import_prometheus(VictoriaMetrics::Client::Scrape.new(time: import_start, samples:), @extra_labels)
    finish = Time.now

    @report_count += 1
    if @report_count % 20 == 1
      Clog.emit("#{@name} metrics report finished", {metrics_report: {
        count: @report_count,
        lookup_duration: render_start - start,
        render_duration: import_start - render_start,
        import_duration: finish - import_start,
        bytes: samples.bytesize,
        lines: samples.count("\n"),
      }})
    end
  rescue VictoriaMetrics::ClientError, Sequel::Error => e
    # Sequel included: the client lookup queries the database.
    Clog.emit("#{@name} metrics report failed", Util.exception_to_hash(e))
  end
end
