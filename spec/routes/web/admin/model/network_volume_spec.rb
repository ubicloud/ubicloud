# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "NetworkVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_network_volume
    admin_account_setup_and_login
  end

  it "displays the NetworkVolume instance page correctly" do
    click_link "NetworkVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NetworkVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NetworkVolume #{@instance.ubid}"
  end
end
