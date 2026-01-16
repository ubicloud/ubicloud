# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "NicAwsResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_nic_aws_resource
    admin_account_setup_and_login
  end

  it "displays the NicAwsResource instance page correctly" do
    click_link "NicAwsResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NicAwsResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - NicAwsResource #{@instance.ubid}"
  end
end
