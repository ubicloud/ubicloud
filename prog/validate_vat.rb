# frozen_string_literal: true

require "countries"

class Prog::ValidateVat < Prog::Base
  subject_is :billing_info

  label def start
    billing_info.update(valid_vat: billing_info.validate_vat)

    pop "VAT validated"
  end
end
