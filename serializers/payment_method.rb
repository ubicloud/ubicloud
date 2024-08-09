# frozen_string_literal: true

class Serializers::PaymentMethod < Serializers::Base
  def self.serialize_internal(pm, options = {})
    {
      id: pm.id,
      ubid: pm.ubid,
      last4: pm.stripe_data["card"]["last4"],
      brand: pm.stripe_data["card"]["brand"],
      exp_month: pm.stripe_data["card"]["exp_month"],
      exp_year: pm.stripe_data["card"]["exp_year"],
      order: pm.order,
      created_at: pm.created_at.strftime("%B %d, %Y")
    }
  end
end
