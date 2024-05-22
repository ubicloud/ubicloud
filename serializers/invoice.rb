# frozen_string_literal: true

require "countries"

class Serializers::Invoice < Serializers::Base
  def self.serialize_internal(inv, options = {})
    base = {
      ubid: inv.id ? inv.ubid : "current",
      path: inv.path,
      name: inv.name,
      filename: "Ubicloud-#{inv.begin_time.strftime("%Y-%m")}-#{inv.invoice_number}",
      date: inv.created_at.strftime("%B %d, %Y"),
      begin_time: inv.begin_time.strftime("%b %d, %Y"),
      end_time: inv.end_time.strftime("%b %d, %Y"),
      subtotal: "$%0.02f" % inv.content["subtotal"],
      credit: "$%0.02f" % inv.content["credit"],
      discount: "$%0.02f" % inv.content["discount"],
      total: "$%0.02f" % inv.content["cost"],
      status: inv.status,
      invoice_number: inv.invoice_number
    }

    if options[:detailed]
      base.merge!(
        billing_name: inv.content.dig("billing_info", "name"),
        billing_email: inv.content.dig("billing_info", "email"),
        billing_address: inv.content.dig("billing_info", "address"),
        billing_country: ISO3166::Country.new(inv.content.dig("billing_info", "country"))&.common_name,
        billing_city: inv.content.dig("billing_info", "city"),
        billing_state: inv.content.dig("billing_info", "state"),
        billing_postal_code: inv.content.dig("billing_info", "postal_code"),
        tax_id: inv.content.dig("billing_info", "tax_id"),
        company_name: inv.content.dig("billing_info", "company_name"),
        issuer_name: inv.content.dig("issuer_info", "name"),
        issuer_address: inv.content.dig("issuer_info", "address"),
        issuer_country: ISO3166::Country.new(inv.content.dig("issuer_info", "country"))&.common_name,
        issuer_city: inv.content.dig("issuer_info", "city"),
        issuer_state: inv.content.dig("issuer_info", "state"),
        issuer_postal_code: inv.content.dig("issuer_info", "postal_code"),
        items: inv.content["resources"].flat_map do |resource|
                 resource["line_items"].map do |line_item|
                   {
                     name: resource["resource_name"],
                     description: line_item["description"],
                     duration: line_item["duration"].to_i,
                     amount: line_item["amount"],
                     cost: line_item["cost"],
                     cost_humanized: humanized_cost(line_item["cost"]),
                     usage: BillingRate.line_item_usage(line_item["resource_type"], line_item["resource_family"], line_item["amount"], line_item["duration"])
                   }
                 end
               end.group_by { _1[:description] }.flat_map do |description, line_items|
                 if line_items.count <= 5 || description.end_with?("GitHub Runner")
                   line_items
                 else
                   duration_sum = line_items.sum { _1[:duration] }
                   amount_sum = line_items.sum { _1[:amount] }
                   cost_sum = line_items.sum { _1[:cost] }
                   {
                     name: "#{line_items.count} x #{description} (Aggregated)",
                     description: description,
                     duration: duration_sum,
                     amount: amount_sum,
                     cost: cost_sum,
                     cost_humanized: humanized_cost(cost_sum),
                     usage: BillingRate.line_item_usage(line_items.first["resource_type"], line_items.first["resource_family"], amount_sum, duration_sum)
                   }
                 end
               end.sort_by { _1[:name] }
      )
    end

    base
  end

  def self.humanized_cost(cost)
    (cost < 0.001) ? "less than $0.001" : "$%0.03f" % cost
  end
end
