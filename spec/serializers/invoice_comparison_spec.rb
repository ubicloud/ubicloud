# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::InvoiceComparison do
  def invoice_data(subtotal:, total: nil, discounts: [], credits: [], vat: nil, usd_to_eur_rate: nil)
    Invoice.new(
      content: {
        "invoice_version" => 2,
        "resources" => [],
        "subtotal" => subtotal.to_f,
        "discounts" => discounts,
        "credits" => credits,
        "discount" => 0.0,
        "credit" => 0.0,
        "cost" => (total || subtotal).to_f,
        "vat_info" => vat,
        "usd_to_eur_rate" => usd_to_eur_rate,
      },
      begin_time: Time.utc(2026, 11),
      end_time: Time.utc(2026, 12),
      created_at: Time.utc(2026, 11, 15),
      status: "current",
    ).serialized
  end

  it "pairs rows by name and uses dashes for missing values" do
    current = invoice_data(
      subtotal: 10,
      total: 12,
      discounts: [{"name" => "Discount", "amount" => 1}],
      credits: [{"name" => "Credit", "amount" => 2}],
      vat: {"rate" => 21, "amount" => 3},
    )
    projected = invoice_data(
      subtotal: 20,
      total: 25,
      credits: [{"name" => "Credit", "amount" => 2}, {"name" => "Runner Credit", "amount" => 1}],
      vat: {"rate" => 21, "amount" => 4},
    )

    rows = described_class.rows(current, projected)

    expect(rows.map(&:name)).to eq(["Subtotal", "Discount", "Credit", "Runner Credit", "VAT (21%)", "Total"])
    expect(rows.map(&:to_date)).to eq(["$10.00", "-$1.00", "-$2.00", "-", "$3.00", "$12.00"])
    expect(rows.map(&:projected)).to eq(["$20.00", "-", "-$2.00", "-$1.00", "$4.00", "$25.00"])
  end

  it "adds EUR rows from the current invoice only" do
    current = invoice_data(subtotal: 10, total: 10, usd_to_eur_rate: 0.9)
    projected = invoice_data(subtotal: 20)

    rows = described_class.rows(current, projected)

    expect(rows.map(&:name)).to eq(["Subtotal", "Total in USD", "Exchange rate", "Total"])
    expect(rows[1].to_date).to eq("$10.00")
    expect(rows[1].projected).to eq("-")
  end

  it "includes VAT from the projected invoice when the current invoice has none" do
    current = invoice_data(subtotal: 10)
    projected = invoice_data(subtotal: 20, vat: {"rate" => 21, "amount" => 4.2})

    rows = described_class.rows(current, projected)

    vat = rows.find { it.name == "VAT (21%)" }
    expect(vat.to_date).to eq("-")
    expect(vat.projected).to eq("$4.20")
  end

  it "includes VAT from the current invoice when the projected invoice has none" do
    current = invoice_data(subtotal: 10, vat: {"rate" => 21, "amount" => 2.1})
    projected = invoice_data(subtotal: 20)

    rows = described_class.rows(current, projected)

    vat = rows.find { it.name == "VAT (21%)" }
    expect(vat.to_date).to eq("$2.10")
    expect(vat.projected).to eq("-")
  end
end
