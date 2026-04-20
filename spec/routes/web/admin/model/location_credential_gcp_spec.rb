# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LocationCredentialGcp" do
  include AdminModelSpecHelper

  before do
    @instance = create_location_credential_gcp
    admin_account_setup_and_login
  end

  it "displays the LocationCredentialGcp instance page correctly" do
    click_link "LocationCredentialGcp"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationCredentialGcp"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationCredentialGcp #{@instance.ubid}"
  end
end
