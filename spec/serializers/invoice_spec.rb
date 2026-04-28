# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Invoice do
  let(:project) { Project.create(name: "test") }

  def line_item(discount_percent: nil)
    item = {
      "description" => "standard-2 Virtual Machine",
      "duration" => 60,
      "amount" => 1.0,
      "cost" => 0.5,
      "resource_type" => "VmVCpu",
      "resource_family" => "standard",
    }
    if discount_percent
      item["discount"] = {"percent" => discount_percent, "amount" => (0.5 * discount_percent / 100.0).round(3)}
    end
    item
  end

  def build_invoice(line_items)
    content = {
      "cost" => 0,
      "subtotal" => 0,
      "credit" => 0,
      "discount" => 0,
      "resources" => [{"resource_name" => "vm-test", "line_items" => line_items}],
      "billing_info" => {"email" => "billing@example.com", "country" => "US"},
    }
    Invoice.create(project_id: project.id, begin_time: Time.utc(2025, 3), end_time: Time.utc(2025, 4), invoice_number: "TEST-001", created_at: Time.now, content:, status: "unpaid")
  end

  describe "aggregation of >100 line items" do
    it "carries the percent through when every grouped item shares the same discount" do
      items = Array.new(101) { line_item(discount_percent: 20) }
      aggregated = described_class.serialize(build_invoice(items)).items.first
      expect(aggregated.name).to start_with("101 x")
      expect(aggregated.discount_percent).to eq 20
      expect(aggregated.discount_amount).to be_within(0.001).of(0.1 * 101)
    end

    it "drops the percent when only some grouped items are discounted" do
      items = Array.new(60) { line_item(discount_percent: 20) } + Array.new(50) { line_item }
      aggregated = described_class.serialize(build_invoice(items)).items.first
      expect(aggregated.discount_percent).to be_nil
      expect(aggregated.discount_amount).to be_within(0.001).of(0.1 * 60)
    end

    it "drops the percent when grouped items have different discount percents" do
      items = Array.new(60) { line_item(discount_percent: 20) } + Array.new(50) { line_item(discount_percent: 30) }
      aggregated = described_class.serialize(build_invoice(items)).items.first
      expect(aggregated.discount_percent).to be_nil
      expect(aggregated.discount_amount).to be_within(0.001).of(0.1 * 60 + 0.15 * 50)
    end
  end
end
