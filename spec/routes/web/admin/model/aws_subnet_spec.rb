# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AwsSubnet" do
  include AdminModelSpecHelper

  before do
    @instance = create_aws_subnet
    admin_account_setup_and_login
  end

  it "displays the AwsSubnet instance page correctly" do
    click_link "AwsSubnet"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsSubnet"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsSubnet #{@instance.ubid}"
  end
end
