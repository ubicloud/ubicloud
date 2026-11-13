# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VpcPeeringAwsResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_vpc_peering_aws_resource
    admin_account_setup_and_login
  end

  it "displays the VpcPeeringAwsResource instance page correctly" do
    click_link "VpcPeeringAwsResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeeringAwsResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VpcPeeringAwsResource #{@instance.ubid}"
  end
end
