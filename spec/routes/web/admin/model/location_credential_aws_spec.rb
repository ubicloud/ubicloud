# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LocationCredentialAws" do
  include AdminModelSpecHelper

  before do
    @instance = create_location_credential_aws
    admin_account_setup_and_login
  end

  it "displays the LocationCredentialAws instance page correctly" do
    click_link "LocationCredentialAws"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationCredentialAws"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationCredentialAws #{@instance.ubid}"
  end
end
