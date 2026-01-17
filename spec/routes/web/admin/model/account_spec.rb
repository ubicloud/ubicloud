# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Account" do
  include AdminModelSpecHelper

  before do
    @instance = create_account
    admin_account_setup_and_login
  end

  it "displays the Account instance page correctly" do
    @instance.update(name: "Test-Admin-Account")
    click_link "Account"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Account - Browse"

    click_link @instance.name
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Account #{@instance.ubid}"
  end
end
