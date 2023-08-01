# frozen_string_literal: true

require_relative "../model"
require "stripe"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods
  one_to_one :project

  include ResourceMethods

  def stripe_data
    if (Stripe.api_key = Config.stripe_secret_key)
      @stripe_data ||= Stripe::Customer.retrieve(stripe_id)
    end
  end

  def after_destroy
    if (Stripe.api_key = Config.stripe_secret_key)
      Stripe::Customer.delete(stripe_id)
    end
    super
  end
end
