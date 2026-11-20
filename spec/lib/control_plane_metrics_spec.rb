# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ControlPlaneMetrics do
  let(:metrics) { Object.new.extend(described_class).tap { it.send(:initialize) } }

  it "renders the metrics in its registry" do
    metrics.registry.counter(:spec_total, docstring: "Spec counter.").increment
    expect(metrics.render).to include "spec_total 1.0"
  end

  it "renders unlabeled gauges only once they are set" do
    expect(metrics.render.lines.reject { it.start_with?("#") }).to be_empty
  end

  it "records nothing when reporting is disabled" do
    allow(Config).to receive(:control_plane_metrics_report_enabled).and_return(false)
    metrics.observe_strand_run(prog: "Test", label: "start", duration: 1)
    metrics.observe_strand_label(prog: "Test", label: "start", outcome: "exit", to: "", duration: 1)
    metrics.observe_ssh_command(prog: "", label: "", outcome: "success", duration: 1)
    metrics.observe_ssh_connect(outcome: "success", duration: 1)
    metrics.observe_monitor_pulse(resource_type: "VmHost", duration: 1)
    metrics.observe_metrics_export(resource_type: "VmHost", outcome: "success", duration: 1)
    metrics.set_monitor_state(resources: {}, export_resources: {}, queue_lengths: {}, idle_workers: {}, active_threads: 1, threads_waiting_for_db: 1)
    metrics.observe_respirate_dispatch(scan_delay: 1, queue_delay: 1, lease_delay: 1, total_delay: 1, queue_size: 1, available_workers: 1, lease_acquired: true, old_strand: false, lease_expired: false)
    metrics.set_respirate_current_strand_delay(1)
    metrics.count_runner_admission(decision: "low_utilization")
    metrics.observe_vm_provision(provider: "metal", arch: "x64", family: "standard", runner: false, allocation: 1, provisioning: 1)
    expect(metrics.render.lines.reject { it.start_with?("#") }).to be_empty
  end

  it "sets monitor state gauges and zeroes label sets that are no longer present" do
    state = {
      export_resources: {{resource_type: "VmHost"} => 4},
      queue_lengths: {{kind: "pulse"} => 2},
      idle_workers: {{kind: "export"} => 3},
      active_threads: 7,
      threads_waiting_for_db: 1,
    }
    metrics.set_monitor_state(resources: {{resource_type: "VmHost", reading: "down"} => 5}, **state)
    rendered = metrics.render
    expect(rendered).to include 'monitor_resources{resource_type="VmHost",reading="down"} 5.0'
    expect(rendered).to include 'metrics_export_resources{resource_type="VmHost"} 4.0'
    expect(rendered).to include 'monitor_queue_length{kind="pulse"} 2.0'
    expect(rendered).to include 'monitor_idle_workers{kind="export"} 3.0'
    expect(rendered).to include "monitor_active_threads 7.0"
    expect(rendered).to include "monitor_threads_waiting_for_db 1.0"

    metrics.set_monitor_state(resources: {{resource_type: "VmHost", reading: "up"} => 5}, **state)
    rendered = metrics.render
    expect(rendered).to include 'monitor_resources{resource_type="VmHost",reading="down"} 0.0'
    expect(rendered).to include 'monitor_resources{resource_type="VmHost",reading="up"} 5.0'
  end
end
