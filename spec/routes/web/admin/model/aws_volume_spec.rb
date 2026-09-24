# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AwsVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_aws_volume
    admin_account_setup_and_login
  end

  it "displays the AwsVolume instance page correctly" do
    click_link "AwsVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsVolume #{@instance.ubid}"
  end
end
