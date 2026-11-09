# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VpcPeeringGcpResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_vpc_peering_gcp_resource
    admin_account_setup_and_login
  end

  it "displays the VpcPeeringGcpResource instance page correctly" do
    click_link "VpcPeeringGcpResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeeringGcpResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeeringGcpResource #{@instance.ubid}"
    expect(page).to have_content @instance.peering_name
  end
end
