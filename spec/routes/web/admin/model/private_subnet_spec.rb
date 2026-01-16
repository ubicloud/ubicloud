# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PrivateSubnet" do
  include AdminModelSpecHelper

  before do
    @instance = create_private_subnet
    admin_account_setup_and_login
  end

  it "displays the PrivateSubnet instance page correctly" do
    click_link "PrivateSubnet"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateSubnet"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateSubnet #{@instance.ubid}"
  end
end
