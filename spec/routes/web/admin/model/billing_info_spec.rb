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

  it "paginates the browse page" do
    oldest_ubid = Array.new(25) do |i|
      ubid = BillingInfo.generate_ubid
      BillingInfo.insert(id: ubid.to_uuid, stripe_id: "cus_test#{i}", created_at: Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{i + 1} minutes", :interval))
      ubid.to_s
    end.last
    click_link "BillingInfo"
    click_link "Next"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BillingInfo - Browse"
    expect(page).to have_content oldest_ubid
  end
end
