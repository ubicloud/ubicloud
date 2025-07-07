# frozen_string_literal: true

require_relative "../model"
require "stripe"
require "countries"
require "excon"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods, order: Sequel.desc(:created_at)
  one_to_one :project

  plugin ResourceMethods, etc_type: true

  def stripe_data
    if (Stripe.api_key = Config.stripe_secret_key)
      @stripe_data ||= begin
        data = Stripe::Customer.retrieve(stripe_id)
        return nil unless data
        address = data["address"] || {}
        metadata = data["metadata"] || {}
        {
          "name" => data["name"],
          "email" => data["email"],
          "address" => [address["line1"], address["line2"]].compact.join(" "),
          "country" => address["country"],
          "city" => address["city"],
          "state" => address["state"],
          "postal_code" => address["postal_code"],
          "tax_id" => metadata["tax_id"],
          "company_name" => metadata["company_name"]
        }
      end
    end
  end

  def has_address?
    !stripe_data&.[]("address").to_s.empty?
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

  def validate_vat
    response = Excon.get("https://ec.europa.eu/taxation_customs/vies/rest-api/ms/#{stripe_data["country"]}/vat/#{stripe_data["tax_id"]}", expects: 200)
    case (status = JSON.parse(response.body)["userError"])
    when "VALID"
      true
    when "INVALID", "INVALID_INPUT"
      false
    else
      fail "Unexpected response from VAT service: #{status}"
    end
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
