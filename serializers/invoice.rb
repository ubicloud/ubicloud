# frozen_string_literal: true

require "countries"

class Serializers::Invoice < Serializers::Base
  def self.serialize_internal(inv, options = {})
    {
      ubid: inv.id ? inv.ubid : "current",
      path: inv.path,
      name: inv.name,
      date: inv.created_at.strftime("%B %d, %Y"),
      begin_time: inv.begin_time.strftime("%b %d, %Y"),
      end_time: inv.end_time.strftime("%b %d, %Y"),
      subtotal: "$%0.02f" % inv.content["subtotal"],
      credit: "$%0.02f" % inv.content["credit"],
      free_inference_tokens_credit: "$%0.02f" % (inv.content["free_inference_tokens_credit"] || 0),
      discount: "$%0.02f" % inv.content["discount"],
      total: "$%0.02f" % inv.content["cost"],
      status: inv.status,
      invoice_number: inv.invoice_number,
      billing_name: inv.content.dig("billing_info", "name"),
      billing_email: inv.content.dig("billing_info", "email"),
      billing_address: inv.content.dig("billing_info", "address"),
      billing_country: ISO3166::Country.new(inv.content.dig("billing_info", "country"))&.common_name,
      billing_city: inv.content.dig("billing_info", "city"),
      billing_state: inv.content.dig("billing_info", "state"),
      billing_postal_code: inv.content.dig("billing_info", "postal_code"),
      billing_in_eu_vat: inv.content.dig("billing_info", "in_eu_vat"),
      tax_id: inv.content.dig("billing_info", "tax_id"),
      company_name: inv.content.dig("billing_info", "company_name"),
      issuer_name: inv.content.dig("issuer_info", "name"),
      issuer_address: inv.content.dig("issuer_info", "address"),
      issuer_country: ISO3166::Country.new(inv.content.dig("issuer_info", "country"))&.common_name,
      issuer_city: inv.content.dig("issuer_info", "city"),
      issuer_state: inv.content.dig("issuer_info", "state"),
      issuer_postal_code: inv.content.dig("issuer_info", "postal_code"),
      issuer_tax_id: inv.content.dig("issuer_info", "tax_id"),
      issuer_trade_id: inv.content.dig("issuer_info", "trade_id"),
      issuer_in_eu_vat: inv.content.dig("issuer_info", "in_eu_vat"),
      vat_rate: inv.content.dig("vat_info", "rate"),
      vat_amount: "$%0.02f" % (inv.content.dig("vat_info", "amount") || 0),
      vat_amount_eur: "€%0.02f" % ((inv.content.dig("vat_info", "amount") || 0) * (inv.content.dig("vat_info", "eur_rate") || 0)),
      vat_reversed: inv.content.dig("vat_info", "reversed"),
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
             end.group_by { it[:description] }.flat_map do |description, line_items|
               if line_items.count > 100 && description.end_with?("Address", "Virtual Machine")
                 duration_sum = line_items.sum { it[:duration] }
                 amount_sum = line_items.sum { it[:amount] }
                 cost_sum = line_items.sum { it[:cost] }
                 {
                   name: "#{line_items.count} x #{description} (Aggregated)",
                   description: description,
                   duration: duration_sum,
                   amount: amount_sum,
                   cost: cost_sum,
                   cost_humanized: humanized_cost(cost_sum),
                   usage: BillingRate.line_item_usage(line_items.first["resource_type"], line_items.first["resource_family"], amount_sum, duration_sum)
                 }
               else
                 line_items
               end
             end.sort_by { it[:name] }
    }
  end

  def self.humanized_cost(cost)
    (cost < 0.001) ? "less than $0.001" : "$%0.03f" % cost
  end
end
