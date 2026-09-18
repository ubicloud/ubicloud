# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ResourceCredit" do
  include AdminModelSpecHelper

  before do
    @instance = create_resource_credit
    admin_account_setup_and_login
  end

  it "displays the ResourceCredit instance page correctly" do
    click_link "ResourceCredit"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ResourceCredit"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ResourceCredit #{@instance.ubid}"
  end
end
