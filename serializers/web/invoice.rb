# frozen_string_literal: true

class Serializers::Web::Invoice < Serializers::Base
  def self.base(inv)
    {
      ubid: inv.ubid,
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
      invoice_number: inv.invoice_number,
      billing_name: inv.content.dig("billing_info", "name"),
      billing_address: inv.content.dig("billing_info", "address"),
      billing_country: ISO3166::Country.new(inv.content.dig("billing_info", "country"))&.common_name,
      billing_city: inv.content.dig("billing_info", "city"),
      billing_state: inv.content.dig("billing_info", "state"),
      billing_postal_code: inv.content.dig("billing_info", "postal_code"),
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
            cost: (line_item["cost"] < 0.001) ? "less than $0.001" : "$%0.03f" % line_item["cost"]
          }
        end
      end.sort_by { _1[:description] }
    }
  end

  structure(:default) do |inv|
    base(inv)
  end
end
