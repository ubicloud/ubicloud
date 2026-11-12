# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ControlPlaneMetrics do
  it "renders strand run durations" do
    described_class.observe_strand_run(prog: "SpecRun", label: "wait", duration: 0.2)
    expect(described_class.render).to include 'strand_run_duration_seconds_count{prog="SpecRun",label="wait"} 1.0'
  end

  it "renders strand label durations" do
    described_class.observe_strand_label(prog: "SpecLabel", label: "start", outcome: "hop", to: "wait", duration: 3)
    expect(described_class.render).to include 'strand_label_duration_seconds_bucket{prog="SpecLabel",label="start",outcome="hop",to="wait",le="5"} 1.0'
  end

  it "renders ssh command durations" do
    described_class.observe_ssh_command(outcome: "spec_timeout", duration: 1.5)
    expect(described_class.render).to include 'ssh_command_duration_seconds_sum{outcome="spec_timeout"} 1.5'
  end

  it "renders monitor pulse durations" do
    described_class.observe_monitor_pulse(resource_type: "SpecPulse", duration: 0.3)
    expect(described_class.render).to include 'monitor_pulse_duration_seconds_bucket{resource_type="SpecPulse",le="0.5"} 1.0'
  end

  it "renders metrics export durations" do
    described_class.observe_metrics_export(resource_type: "SpecExport", outcome: "failure", duration: 2)
    expect(described_class.render).to include 'metrics_export_duration_seconds_count{resource_type="SpecExport",outcome="failure"} 1.0'
  end

  it "renders unlabeled gauges only once they are set" do
    metrics = Object.new.extend(described_class)
    metrics.send(:initialize)
    expect(metrics.render.lines.reject { it.start_with?("#") }).to be_empty
  end

  it "sets monitor state gauges and zeroes label sets that are no longer present" do
    state = {
      export_resources: {{resource_type: "SpecExport"} => 4},
      queue_lengths: {{kind: "pulse"} => 2},
      idle_workers: {{kind: "export"} => 3},
      active_threads: 7,
      threads_waiting_for_db: 1,
    }
    described_class.set_monitor_state(resources: {{resource_type: "SpecGauge", reading: "down"} => 5}, **state)
    rendered = described_class.render
    expect(rendered).to include 'monitor_resources{resource_type="SpecGauge",reading="down"} 5.0'
    expect(rendered).to include 'metrics_export_resources{resource_type="SpecExport"} 4.0'
    expect(rendered).to include 'monitor_queue_length{kind="pulse"} 2.0'
    expect(rendered).to include 'monitor_idle_workers{kind="export"} 3.0'
    expect(rendered).to include "monitor_active_threads 7.0"
    expect(rendered).to include "monitor_threads_waiting_for_db 1.0"

    described_class.set_monitor_state(resources: {{resource_type: "SpecGauge", reading: "up"} => 5}, **state)
    rendered = described_class.render
    expect(rendered).to include 'monitor_resources{resource_type="SpecGauge",reading="down"} 0.0'
    expect(rendered).to include 'monitor_resources{resource_type="SpecGauge",reading="up"} 5.0'
  end
end
