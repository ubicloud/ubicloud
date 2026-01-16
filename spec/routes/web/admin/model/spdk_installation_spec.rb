# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "SpdkInstallation" do
  include AdminModelSpecHelper

  before do
    @instance = create_spdk_installation
    admin_account_setup_and_login
  end

  it "displays the SpdkInstallation instance page correctly" do
    click_link "SpdkInstallation"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - SpdkInstallation"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - SpdkInstallation #{@instance.ubid}"
  end
end
