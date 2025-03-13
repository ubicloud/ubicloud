# frozen_string_literal: true

require "countries"

class Prog::ValidateVat < Prog::Base
  subject_is :billing_info

  label def start
    billing_info.update(valid_vat: billing_info.validate_vat)

    if !billing_info.valid_vat && (email = Config.invalid_vat_notification_email)
      stripe_data = billing_info.stripe_data
      Util.send_email(email, "Customer entered invalid VAT",
        greeting: "Hello,",
        body: ["Customer entered invalid VAT.",
          "Project ID: #{billing_info.project.ubid}",
          "Name: #{stripe_data["name"]}",
          "E-mail: #{stripe_data["email"]}",
          "Country Code: #{stripe_data["country"]}",
          "Country: #{billing_info.country.common_name}",
          "Company Name: #{stripe_data["company_name"]}",
          "VAT ID: #{stripe_data["tax_id"]}"])
    end

    pop "VAT validated"
  end
end
