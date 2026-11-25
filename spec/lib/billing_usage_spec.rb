# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BillingUsage do
  describe ".amount_billed_scale" do
    it "does not scale before seven full days of the month" do
      expect(described_class.amount_billed_scale(Time.utc(2026, 11, 7, 23, 59, 59))).to be_nil
    end

    it "scales once seven full days have elapsed" do
      expect(described_class.amount_billed_scale(Time.utc(2026, 11, 8))).to be_within(1e-12).of(30.0 / 7)
    end
  end
end
