# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ResourceDiscount" do
  include AdminModelSpecHelper

  before do
    @instance = create_resource_discount
    admin_account_setup_and_login
  end

  it "displays the ResourceDiscount instance page correctly" do
    click_link "ResourceDiscount"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ResourceDiscount"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ResourceDiscount #{@instance.ubid}"
  end
end
