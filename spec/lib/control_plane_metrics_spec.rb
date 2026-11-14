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
    described_class.observe_ssh_command(prog: "SpecSsh", label: "run", outcome: "timeout", duration: 1.5)
    expect(described_class.render).to include 'ssh_command_duration_seconds_sum{prog="SpecSsh",label="run",outcome="timeout"} 1.5'
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

  it "renders respirate dispatch metrics" do
    described_class.observe_respirate_dispatch(scan_delay: 0.2, queue_delay: 0.003, lease_delay: 0.002, total_delay: 0.205, queue_size: 3, available_workers: 2, lease_acquired: true, old_strand: nil, lease_expired: nil)
    described_class.set_respirate_current_strand_delay(0.9)
    rendered = described_class.render
    expect(rendered).to include 'respirate_strand_delay_seconds_bucket{stage="scan",le="0.25"}'
    expect(rendered).to include 'respirate_dispatches_total{lease_acquired="true",old_strand="false",lease_expired="false"}'
    expect(rendered).to include "respirate_queue_size 3.0"
    expect(rendered).to include "respirate_available_workers 2.0"
    expect(rendered).to include "respirate_current_strand_delay_seconds 0.9"
  end

  it "counts runner admissions" do
    described_class.count_runner_admission(decision: "spec_decision")
    expect(described_class.render).to include 'runner_admissions_total{decision="spec_decision"} 1.0'
  end

  it "renders vm provision durations by stage" do
    described_class.observe_vm_provision(provider: "spec", arch: "arm64", runner: true, allocation: 3, provisioning: 40)
    rendered = described_class.render
    expect(rendered).to include 'vm_provision_duration_seconds_bucket{provider="spec",stage="allocation",arch="arm64",runner="true",le="5"} 1.0'
    expect(rendered).to include 'vm_provision_duration_seconds_sum{provider="spec",stage="provisioning",arch="arm64",runner="true"} 40.0'
  end

  it "renders github runner durations" do
    described_class.observe_github_runner(stage: "allocation", vm_size: "standard-2", arch: "x64", duration: 12)
    expect(described_class.render).to include 'github_runner_duration_seconds_bucket{stage="allocation",vm_size="standard-2",arch="x64",le="15"} 1.0'
  end
end
