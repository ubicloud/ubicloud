# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Location" do
  include AdminModelSpecHelper

  before do
    @instance = create_location
    admin_account_setup_and_login
  end

  it "displays the Location instance page correctly" do
    click_link "Location"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Location"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Location #{@instance.ubid}"
  end
end
