# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LocationAz" do
  include AdminModelSpecHelper

  before do
    @instance = create_location_az
    admin_account_setup_and_login
  end

  it "displays the LocationAz instance page correctly" do
    click_link "LocationAz"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationAz"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationAz #{@instance.ubid}"
  end
end
