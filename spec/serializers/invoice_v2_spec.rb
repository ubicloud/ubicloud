# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::InvoiceV2 do
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

  def build_invoice(line_items, credits: [], discounts: [])
    content = {
      "cost" => 0,
      "subtotal" => 0,
      "credit" => 0,
      "discount" => 0,
      "credits" => credits,
      "discounts" => discounts,
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

  describe "credits and discounts breakdown" do
    it "serializes credits as dollar-formatted BreakdownData entries" do
      invoice = build_invoice([line_item], credits: [{"name" => "Test Credit", "amount" => 10.0}, {"name" => "GitHub Runner Credit", "amount" => 2.5}])
      serialized = described_class.serialize(invoice)

      expect(serialized.credits).to eq([
        described_class::BreakdownData.new(name: "Test Credit", amount: "$10.00"),
        described_class::BreakdownData.new(name: "GitHub Runner Credit", amount: "$2.50"),
      ])
    end

    it "serializes discounts as dollar-formatted BreakdownData entries" do
      invoice = build_invoice([line_item], discounts: [{"name" => "20% off VMs", "amount" => 0.1}])
      serialized = described_class.serialize(invoice)

      expect(serialized.discounts).to eq([described_class::BreakdownData.new(name: "20% off VMs", amount: "$0.10")])
    end

    it "returns empty arrays when there are no credits or discounts" do
      serialized = described_class.serialize(build_invoice([line_item]))

      expect(serialized.credits).to eq([])
      expect(serialized.discounts).to eq([])
    end

    it "still includes fields inherited from InvoiceV1" do
      invoice = build_invoice([line_item], credits: [{"name" => "Test Credit", "amount" => 10.0}])
      serialized = described_class.serialize(invoice)

      expect(serialized.invoice_number).to eq("TEST-001")
      expect(serialized.items.first.description).to eq("standard-2 Virtual Machine")
    end
  end
end
