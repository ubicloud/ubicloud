# frozen_string_literal: true

require_relative "../model"
require "stripe"

class PaymentMethod < Sequel::Model
  many_to_one :billing_info

  plugin ResourceMethods

  def stripe_data
    if (Stripe.api_key = Config.stripe_secret_key)
      @stripe_data ||= begin
        data = Stripe::PaymentMethod.retrieve(stripe_id)
        card = data["card"]
        {
          "last4" => card["last4"],
          "brand" => card["brand"],
          "exp_month" => card["exp_month"],
          "exp_year" => card["exp_year"]
        }
      end
    end
  end

  def after_destroy
    if (Stripe.api_key = Config.stripe_secret_key)
      Stripe::PaymentMethod.detach(stripe_id)
    end
    super
  end
end

# Table: payment_method
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  stripe_id         | text                     | NOT NULL
#  order             | integer                  |
#  billing_info_id   | uuid                     |
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  card_fingerprint  | text                     |
#  fraud             | boolean                  | NOT NULL DEFAULT false
#  preauth_amount    | integer                  |
#  preauth_intent_id | text                     |
# Indexes:
#  payment_method_pkey                  | PRIMARY KEY btree (id)
#  payment_method_preauth_intent_id_key | UNIQUE btree (preauth_intent_id)
#  payment_method_stripe_id_key         | UNIQUE btree (stripe_id)
# Foreign key constraints:
#  payment_method_billing_info_id_fkey | (billing_info_id) REFERENCES billing_info(id)
