# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "NicGcpResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_nic_gcp_resource
    admin_account_setup_and_login
  end

  it "displays the NicGcpResource instance page correctly" do
    click_link "NicGcpResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NicGcpResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NicGcpResource #{@instance.ubid}"
  end
end
