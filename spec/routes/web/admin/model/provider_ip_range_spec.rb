# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ProviderIpRange" do
  include AdminModelSpecHelper

  before do
    @instance = create_provider_ip_range
    admin_account_setup_and_login
  end

  it "displays the ProviderIpRange instance page correctly" do
    click_link "ProviderIpRange"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ProviderIpRange"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ProviderIpRange #{@instance.ubid}"
  end
end
