# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "TrustedJwtIssuer" do
  include AdminModelSpecHelper

  before do
    @instance = create_trusted_jwt_issuer
    admin_account_setup_and_login
  end

  it "displays the TrustedJwtIssuer instance page correctly" do
    click_link "TrustedJwtIssuer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - TrustedJwtIssuer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - TrustedJwtIssuer #{@instance.ubid}"
  end
end
