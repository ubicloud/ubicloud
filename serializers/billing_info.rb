# frozen_string_literal: true

require "countries"

class Serializers::BillingInfo < Serializers::Base
  def self.serialize_internal(bi, options = {})
    {
      id: bi.id,
      ubid: bi.ubid
    }.merge(bi.stripe_data ? {
      name: bi.stripe_data["name"],
      email: bi.stripe_data["email"],
      address: [bi.stripe_data["address"]["line1"], bi.stripe_data["address"]["line2"]].compact.join(" "),
      country: bi.stripe_data["address"]["country"],
      city: bi.stripe_data["address"]["city"],
      state: bi.stripe_data["address"]["state"],
      postal_code: bi.stripe_data["address"]["postal_code"],
      tax_id: bi.stripe_data["metadata"]["tax_id"],
      company_name: bi.stripe_data["metadata"]["company_name"]
    } : {})
  end
end
