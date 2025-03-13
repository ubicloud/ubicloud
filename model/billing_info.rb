# frozen_string_literal: true

require_relative "../model"
require "stripe"
require "countries"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods
  one_to_one :project

  include ResourceMethods

  def stripe_data
    if (Stripe.api_key = Config.stripe_secret_key)
      @stripe_data ||= begin
        data = Stripe::Customer.retrieve(stripe_id)
        {
          "name" => data["name"],
          "email" => data["email"],
          "address" => [data["address"]["line1"], data["address"]["line2"]].compact.join(" "),
          "country" => data["address"]["country"],
          "city" => data["address"]["city"],
          "state" => data["address"]["state"],
          "postal_code" => data["address"]["postal_code"],
          "tax_id" => data["metadata"]["tax_id"],
          "company_name" => data["metadata"]["company_name"]
        }
      end
    end
  end

  def country
    ISO3166::Country.new(stripe_data["country"])
  end

  def after_destroy
    if (Stripe.api_key = Config.stripe_secret_key)
      Stripe::Customer.delete(stripe_id)
    end
    super
  end
end

# Table: billing_info
# Columns:
#  id         | uuid                     | PRIMARY KEY
#  stripe_id  | text                     | NOT NULL
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
#  valid_vat  | boolean                  |
# Indexes:
#  billing_info_pkey          | PRIMARY KEY btree (id)
#  billing_info_stripe_id_key | UNIQUE btree (stripe_id)
# Referenced By:
#  payment_method | payment_method_billing_info_id_fkey | (billing_info_id) REFERENCES billing_info(id)
#  project        | project_billing_info_id_fkey        | (billing_info_id) REFERENCES billing_info(id)
