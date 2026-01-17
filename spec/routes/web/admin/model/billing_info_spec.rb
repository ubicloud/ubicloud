# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "BillingInfo" do
  include AdminModelSpecHelper

  before do
    @instance = create_billing_info
    admin_account_setup_and_login
  end

  it "displays the BillingInfo instance page correctly" do
    click_link "BillingInfo"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BillingInfo - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BillingInfo #{@instance.ubid}"
  end
end
