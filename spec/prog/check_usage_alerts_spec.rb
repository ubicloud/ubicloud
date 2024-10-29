# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckUsageAlerts do
  subject(:cua) {
    described_class.new(Strand.new(prog: "CheckUsageAlerts"))
  }

  describe "#wait" do
    it "triggers alerts if usage is exceeded given threshold" do
      exceeded = instance_double(UsageAlert, limit: 100, project: instance_double(Project, current_invoice: instance_double(Invoice, content: {"cost" => 1000})))
      not_exceeded = instance_double(UsageAlert, limit: 100, project: instance_double(Project, current_invoice: instance_double(Invoice, content: {"cost" => 10})))
      expect(UsageAlert).to receive(:where).and_return([exceeded, not_exceeded])
      expect(exceeded).to receive(:trigger)
      expect(not_exceeded).not_to receive(:trigger)
      expect { cua.wait }.to nap(5 * 60)
    end
  end
end
