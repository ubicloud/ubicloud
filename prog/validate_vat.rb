# frozen_string_literal: true

require "countries"

class Prog::ValidateVat < Prog::Base
  subject_is :billing_info

  label def start
    billing_info.update(valid_vat: billing_info.validate_vat)

    if !billing_info.valid_vat && (email = billing_info.email || billing_info.project.accounts.first&.email || Config.invalid_vat_notification_email)
      Util.send_email(email, "Your VAT number could not be verified",
        greeting: "Hello,",
        body: ["The VAT number you entered, \"#{billing_info.stripe_data["tax_id"]}\", could not be verified in the VIES system.",
          "To ensure the correct tax treatment is applied, please provide a valid VAT number. You can confirm the status of your VAT number in the VIES database using the link below.",
          "If a valid VAT number is not provided, VAT may be applied to your invoices.",
          "If you have any questions or require assistance, please contact us at support@ubicloud.com."],
        button_title: "Check VAT in VIES",
        button_link: "https://ec.europa.eu/taxation_customs/vies/#/vat-validation",
        cc: Config.invalid_vat_notification_email)
    end

    pop "VAT validated"
  end
end
