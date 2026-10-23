# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VpcPeering" do
  include AdminModelSpecHelper

  before do
    @instance = create_vpc_peering
    admin_account_setup_and_login
  end

  it "displays the VpcPeering instance page correctly" do
    click_link "VpcPeering"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeering"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeering #{@instance.ubid}"
    expect(page).to have_content "10.200.0.0/16"
  end
end
