# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "BillingRecord" do
  include AdminModelSpecHelper

  before do
    @instance = create_billing_record
    admin_account_setup_and_login
  end

  it "displays the BillingRecord instance page correctly" do
    click_link "BillingRecord"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BillingRecord"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BillingRecord #{@instance.ubid}"

    rate = @instance.billing_rate
    expect(page).to have_content("Billing Rate")
    expect(page).to have_content(rate["resource_type"])
    expect(page).to have_content(rate["unit_price"].to_s)
  end
end
