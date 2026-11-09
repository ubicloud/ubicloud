# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AcmeProvider" do
  include AdminModelSpecHelper

  before do
    @instance = create_acme_provider
    admin_account_setup_and_login
  end

  it "displays the AcmeProvider instance page correctly" do
    click_link "AcmeProvider"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AcmeProvider"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AcmeProvider #{@instance.ubid}"
    expect(page).to have_content "https://ca.example.com/directory"
    expect(page).to have_no_content "test-acme-provider-key"
  end
end
