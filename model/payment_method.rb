# frozen_string_literal: true

require_relative "../model"

class PaymentMethod < Sequel::Model
  many_to_one :billing_info, read_only: true

  plugin ResourceMethods

  def self.fraud?(card_fingerprint)
    !where(fraud: true, card_fingerprint:).empty?
  end

  def stripe_data
    if Config.stripe_secret_key
      @stripe_data ||= StripeClient.payment_methods.retrieve(stripe_id)["card"].to_h.transform_keys!(&:to_s).slice(*%w[last4 brand exp_month exp_year country funding wallet checks])
    end
  end

  def after_destroy
    if Config.stripe_secret_key
      StripeClient.payment_methods.detach(stripe_id)
    end
    super
  end

  def path
    "/billing/payment-method/#{ubid}"
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
