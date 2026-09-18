# frozen_string_literal: true

require "countries"

class Serializers::InvoiceV2 < Serializers::InvoiceV1
  InvoiceData = Data.define(*Serializers::InvoiceV1::InvoiceData.members, :discounts, :credits)
  ItemData = Data.define(*Serializers::InvoiceV1::ItemData.members, :discount_name, :credits)
  BreakdownData = Data.define(:name, :amount)

  def self.hash_for(inv, options)
    hash = super
    %i[credits discounts].each do |k|
      hash[k] = inv.content[k.to_s].map { |d| BreakdownData.new(name: d["name"], amount: "$%0.02f" % d["amount"]) }
    end
    hash[:items] = inv.content["resources"].flat_map do |resource|
      resource["line_items"].map do |line_item|
        discount = line_item["discount"] || {"percent" => nil, "amount" => 0, "name" => nil}
        credits = (line_item["credits"] || []).map { |c| BreakdownData.new(name: c["name"], amount: c["amount"]) }
        ItemData.new(
          name: resource["resource_name"],
          description: line_item["description"],
          duration: line_item["duration"].to_i,
          amount: line_item["amount"],
          cost: line_item["cost"],
          cost_humanized: humanized_cost(line_item["cost"]),
          resource_type: line_item["resource_type"],
          resource_family: line_item["resource_family"],
          usage: BillingRate.line_item_usage(line_item["resource_type"], line_item["resource_family"], line_item["amount"], line_item["duration"]),
          discount_percent: discount["percent"],
          discount_amount: discount["amount"],
          discount_name: discount["name"],
          credits:,
        )
      end
    end.group_by { it.description }.flat_map do |description, line_items|
      if line_items.count > 100 && description.end_with?("Address", "Virtual Machine")
        duration_sum = line_items.sum { it.duration }
        amount_sum = line_items.sum { it.amount }
        cost_sum = line_items.sum { it.cost }
        discount_amount_sum = line_items.sum { it.discount_amount }
        discount_percents = line_items.map(&:discount_percent).uniq
        discount_percent = (discount_percents.length == 1) ? discount_percents.first : nil
        discount_names = line_items.map(&:discount_name).uniq
        discount_name = (discount_names.length == 1) ? discount_names.first : nil

        usage = BillingRate.line_item_usage(
          line_items.first.resource_type,
          line_items.first.resource_family,
          amount_sum,
          duration_sum,
        )

        credits_sum = line_items.flat_map(&:credits).group_by(&:name).map do |name, cs|
          BreakdownData.new(name:, amount: cs.sum(&:amount).round(3))
        end

        ItemData.new(
          name: "#{line_items.count} x #{description} (Aggregated)",
          description:,
          duration: duration_sum,
          amount: amount_sum,
          cost: cost_sum,
          cost_humanized: humanized_cost(cost_sum),
          resource_type: nil,
          resource_family: nil,
          usage:,
          discount_percent:,
          discount_amount: discount_amount_sum,
          discount_name:,
          credits: credits_sum,
        )
      else
        line_items
      end
    end.sort_by(&:name)
    hash
  end
end
