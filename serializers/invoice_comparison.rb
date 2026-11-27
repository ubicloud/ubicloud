# frozen_string_literal: true

class Serializers::InvoiceComparison
  Row = Data.define(:name, :to_date, :projected)

  def self.rows(current, projected)
    rows = [row("Subtotal", current.subtotal, projected.subtotal)]
    add_adjustment_rows(rows, :discounts, current, projected)
    add_adjustment_rows(rows, :credits, current, projected)
    add_vat_row(rows, current, projected)
    if current.usd_to_eur_rate
      rows << row("Total in USD", current.total_usd, "-")
      rows << row("Exchange rate", current.usd_to_eur_rate_string, "-")
    end
    rows << row("Total", current.total, projected.total)
    rows
  end

  def self.row(name, to_date, projected)
    Row.new(name, to_date, projected)
  end
  private_class_method :row

  def self.add_adjustment_rows(rows, type, current, projected)
    current_items = current.public_send(type)
    projected_items = projected.public_send(type)
    (current_items.map(&:name) + projected_items.map(&:name)).uniq.each do |name|
      current_item = current_items.find { it.name == name }
      projected_item = projected_items.find { it.name == name }
      rows << row(name, current_item ? "-#{current_item.amount}" : "-", projected_item ? "-#{projected_item.amount}" : "-")
    end
  end
  private_class_method :add_adjustment_rows

  def self.add_vat_row(rows, current, projected)
    current_has_vat = current.vat_amount != "$0.00"
    projected_has_vat = projected.vat_amount != "$0.00"
    return unless current_has_vat || projected_has_vat

    rate = current.vat_rate || projected.vat_rate
    rows << row("VAT (#{rate}%)", current_has_vat ? current.vat_amount : "-", projected_has_vat ? projected.vat_amount : "-")
  end
  private_class_method :add_vat_row
end
