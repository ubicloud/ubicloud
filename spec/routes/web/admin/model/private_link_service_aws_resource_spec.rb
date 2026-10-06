# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PrivateLinkServiceAwsResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_private_link_service_aws_resource
    admin_account_setup_and_login
  end

  it "displays the PrivateLinkServiceAwsResource instance page correctly" do
    click_link "PrivateLinkServiceAwsResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateLinkServiceAwsResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PrivateLinkServiceAwsResource #{@instance.ubid}"
  end
end
