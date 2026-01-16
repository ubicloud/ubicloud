# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LocationAwsAz" do
  include AdminModelSpecHelper

  before do
    @instance = create_location_aws_az
    admin_account_setup_and_login
  end

  it "displays the LocationAwsAz instance page correctly" do
    click_link "LocationAwsAz"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationAwsAz"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocationAwsAz #{@instance.ubid}"
  end
end
