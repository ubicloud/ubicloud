# frozen_string_literal: true

require_relative "../model"
require "countries"
require "excon"

class BillingInfo < Sequel::Model
  one_to_many :payment_methods, order: Sequel.desc(:created_at), remover: nil, clearer: nil
  one_to_one :project, read_only: true

  plugin ResourceMethods

  def self.update_or_create_stripe_customer(project, name:, email:, country:, state:, city:, postal_code:, address:, tax_id:, company_name:, note:)
    tax_id = tax_id.to_s.gsub(/[^a-zA-Z0-9]/, "")
    customer_params = {
      name:,
      email: email.strip,
      address: {country:, state:, city:, postal_code:, line1: address, line2: nil},
      metadata: {tax_id:, company_name:, note:},
    }

    if (billing_info = project.billing_info)
      tax_id_changed = tax_id != billing_info.stripe_data["tax_id"].to_s
      StripeClient.customers.update(billing_info.stripe_id, customer_params)
    else
      tax_id_changed = !tax_id.empty?
      customer = StripeClient.customers.create(customer_params)
      DB.transaction do
        billing_info = create(stripe_id: customer["id"])
        project.update(billing_info_id: billing_info.id)
      end
    end

    if tax_id_changed
      DB.transaction do
        billing_info.update(valid_vat: nil)
        if !tax_id.empty? && ISO3166::Country.new(country)&.in_eu_vat?
          Strand.create(prog: "ValidateVat", label: "start", stack: [{subject_id: billing_info.id}])
        end
      end
    end

    billing_info
  end

  def stripe_data
    if Config.stripe_secret_key
      @stripe_data ||= begin
        data = StripeClient.customers.retrieve(stripe_id)
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
          "company_name" => metadata["company_name"],
          "note" => metadata["note"],
        }
      end
    end
  end

  def has_address?
    !stripe_data&.[]("address").to_s.empty?
  end

  def email
    stripe_data&.[]("email")
  end

  def country
    ISO3166::Country.new(stripe_data["country"])
  end

  def after_destroy
    if Config.stripe_secret_key
      StripeClient.customers.delete(stripe_id)
    end
    super
  end

  VAT_COUNTRY_CODES = {"GR" => "EL"}.freeze

  def validate_vat
    country_code = VAT_COUNTRY_CODES.fetch(stripe_data["country"], stripe_data["country"])
    response = Excon.get("https://ec.europa.eu/taxation_customs/vies/rest-api/ms/#{country_code}/vat/#{stripe_data["tax_id"]}", expects: 200)
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
