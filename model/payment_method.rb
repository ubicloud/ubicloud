# frozen_string_literal: true

require_relative "../model"
require "stripe"

class PaymentMethod < Sequel::Model
  many_to_one :billing_info

  include ResourceMethods

  def stripe_data
    if (Stripe.api_key = Config.stripe_secret_key)
      @stripe_data ||= Stripe::PaymentMethod.retrieve(stripe_id)
    end
  end

  def after_destroy
    if (Stripe.api_key = Config.stripe_secret_key)
      Stripe::PaymentMethod.detach(stripe_id)
    end
    super
  end
end
