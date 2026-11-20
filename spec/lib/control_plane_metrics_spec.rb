# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ControlPlaneMetrics do
  let(:metrics) { Object.new.extend(described_class).tap { it.send(:initialize) } }

  it "renders the metrics in its registry" do
    metrics.registry.counter(:spec_total, docstring: "Spec counter.").increment
    expect(metrics.render).to include "spec_total 1.0"
  end
end
