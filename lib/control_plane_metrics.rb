# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"

module ControlPlaneMetrics
  STRAND_RUN_BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30, 45, 60, 75, 90].freeze
  STRAND_LABEL_BUCKETS = [1, 5, 15, 60, 300, 900, 3600, 14400, 86400].freeze
  SSH_COMMAND_BUCKETS = [0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 10, 20, 30, 60].freeze
  MONITOR_PULSE_BUCKETS = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120].freeze
  METRICS_EXPORT_BUCKETS = [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 100].freeze

  UNLABELED_GAUGES = {
    monitor_active_threads: "Threads in the monitor process beyond its fixed worker and internal threads.",
    monitor_threads_waiting_for_db: "Threads waiting for a database connection in the monitor process.",
  }.freeze

  def initialize
    @registry = Prometheus::Client::Registry.new
    @strand_run_duration = @registry.histogram(
      :strand_run_duration_seconds,
      docstring: "Duration of a single strand run.",
      labels: [:prog, :label],
      buckets: STRAND_RUN_BUCKETS,
    )
    @strand_label_duration = @registry.histogram(
      :strand_label_duration_seconds,
      docstring: "Time a strand spent in a label before hopping out of it or exiting.",
      labels: [:prog, :label, :outcome],
      buckets: STRAND_LABEL_BUCKETS,
    )
    @ssh_command_duration = @registry.histogram(
      :ssh_command_duration_seconds,
      docstring: "Duration of commands run over SSH.",
      labels: [:outcome],
      buckets: SSH_COMMAND_BUCKETS,
    )
    @monitor_pulse_duration = @registry.histogram(
      :monitor_pulse_duration_seconds,
      docstring: "Duration of monitor pulse checks.",
      labels: [:resource_type],
      buckets: MONITOR_PULSE_BUCKETS,
    )
    @metrics_export_duration = @registry.histogram(
      :metrics_export_duration_seconds,
      docstring: "Duration of metrics exports.",
      labels: [:resource_type, :outcome],
      buckets: METRICS_EXPORT_BUCKETS,
    )
    @monitor_resources = @registry.gauge(
      :monitor_resources,
      docstring: "Monitored resources by type and latest pulse reading.",
      labels: [:resource_type, :reading],
    )
    @metrics_export_resources = @registry.gauge(
      :metrics_export_resources,
      docstring: "Metrics export resources by type.",
      labels: [:resource_type],
    )
    @monitor_queue_length = @registry.gauge(
      :monitor_queue_length,
      docstring: "Jobs waiting in the monitor submit queue.",
      labels: [:kind],
    )
    @monitor_idle_workers = @registry.gauge(
      :monitor_idle_workers,
      docstring: "Monitor worker threads waiting for a job.",
      labels: [:kind],
    )
    @unlabeled_gauges = {}
  end

  def observe_strand_run(prog:, label:, duration:)
    @strand_run_duration.observe(duration, labels: {prog:, label:})
  end

  def observe_strand_label(prog:, label:, outcome:, duration:)
    @strand_label_duration.observe(duration, labels: {prog:, label:, outcome:})
  end

  def observe_ssh_command(outcome:, duration:)
    @ssh_command_duration.observe(duration, labels: {outcome:})
  end

  def observe_monitor_pulse(resource_type:, duration:)
    @monitor_pulse_duration.observe(duration, labels: {resource_type:})
  end

  def observe_metrics_export(resource_type:, outcome:, duration:)
    @metrics_export_duration.observe(duration, labels: {resource_type:, outcome:})
  end

  def set_monitor_state(resources:, export_resources:, queue_lengths:, idle_workers:, active_threads:, threads_waiting_for_db:)
    set_labeled(@monitor_resources, resources)
    set_labeled(@metrics_export_resources, export_resources)
    set_labeled(@monitor_queue_length, queue_lengths)
    set_labeled(@monitor_idle_workers, idle_workers)
    unlabeled_gauge(:monitor_active_threads).set(active_threads)
    unlabeled_gauge(:monitor_threads_waiting_for_db).set(threads_waiting_for_db)
  end

  def render
    Prometheus::Client::Formats::Text.marshal(@registry)
  end

  private def unlabeled_gauge(name)
    @unlabeled_gauges[name] ||= @registry.gauge(name, docstring: UNLABELED_GAUGES.fetch(name))
  end

  private def set_labeled(gauge, values)
    (gauge.values.keys - values.keys).each { gauge.set(0, labels: it) }
    values.each { |labels, value| gauge.set(value, labels:) }
  end

  extend self

  initialize
end
