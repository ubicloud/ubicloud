# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ControlPlaneMetrics do
  let(:metrics) { Object.new.extend(described_class).tap { it.send(:initialize) } }

  it "renders the metrics in its registry" do
    metrics.registry.counter(:spec_total, docstring: "Spec counter.").increment
    expect(metrics.render).to include "spec_total 1.0"
  end

  it "records nothing when reporting is disabled" do
    allow(Config).to receive(:control_plane_metrics_report_enabled).and_return(false)
    metrics.observe_strand_run(prog: "Test", label: "start", duration: 1)
    metrics.observe_strand_label(prog: "Test", label: "start", outcome: "exit", to: "", duration: 1)
    expect(metrics.render.lines.reject { it.start_with?("#") }).to be_empty
  end
end
