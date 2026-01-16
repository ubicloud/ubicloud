# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PrivateSubnetAwsResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_private_subnet_aws_resource
    admin_account_setup_and_login
  end

  it "displays the PrivateSubnetAwsResource instance page correctly" do
    click_link "PrivateSubnetAwsResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateSubnetAwsResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateSubnetAwsResource #{@instance.ubid}"
  end
end
