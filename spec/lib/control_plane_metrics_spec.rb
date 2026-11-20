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
