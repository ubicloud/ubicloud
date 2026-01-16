# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ProjectDiscountCode" do
  include AdminModelSpecHelper

  before do
    @instance = create_project_discount_code
    admin_account_setup_and_login
  end

  it "displays the ProjectDiscountCode instance page correctly" do
    click_link "ProjectDiscountCode"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ProjectDiscountCode"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ProjectDiscountCode #{@instance.ubid}"
  end
end
