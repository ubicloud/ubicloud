# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"

module ControlPlaneMetrics
  STRAND_RUN_BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30, 45, 60, 75, 90].freeze
  STRAND_LABEL_BUCKETS = [1, 5, 15, 60, 300, 900, 3600, 14400, 86400].freeze
  SSH_BUCKETS = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 10, 20, 30, 60].freeze

  attr_reader :registry

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
      labels: [:prog, :label, :outcome, :to],
      buckets: STRAND_LABEL_BUCKETS,
    )
    @ssh_command_duration = @registry.histogram(
      :ssh_command_duration_seconds,
      docstring: "Duration of commands run over SSH, excluding connection setup, by the strand prog and label that ran them.",
      labels: [:prog, :label, :outcome],
      buckets: SSH_BUCKETS,
    )
    @ssh_connect_duration = @registry.histogram(
      :ssh_connect_duration_seconds,
      docstring: "Duration of establishing new SSH sessions, including the session lock.",
      labels: [:outcome],
      buckets: SSH_BUCKETS,
    )
  end

  def observe_strand_run(prog:, label:, duration:)
    return unless Config.control_plane_metrics_report_enabled

    @strand_run_duration.observe(duration, labels: {prog:, label:})
  end

  def observe_strand_label(prog:, label:, outcome:, to:, duration:)
    return unless Config.control_plane_metrics_report_enabled

    @strand_label_duration.observe(duration, labels: {prog:, label:, outcome:, to:})
  end

  def observe_ssh_command(prog:, label:, outcome:, duration:)
    return unless Config.control_plane_metrics_report_enabled

    @ssh_command_duration.observe(duration, labels: {prog:, label:, outcome:})
  end

  def observe_ssh_connect(outcome:, duration:)
    return unless Config.control_plane_metrics_report_enabled

    @ssh_connect_duration.observe(duration, labels: {outcome:})
  end

  def render
    Prometheus::Client::Formats::Text.marshal(@registry)
  end

  extend self

  initialize
end
