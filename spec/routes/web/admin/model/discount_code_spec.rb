# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "DiscountCode" do
  include AdminModelSpecHelper

  before do
    @instance = create_discount_code
    admin_account_setup_and_login
  end

  it "displays the DiscountCode instance page correctly" do
    click_link "DiscountCode"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DiscountCode"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DiscountCode #{@instance.ubid}"
  end
end
