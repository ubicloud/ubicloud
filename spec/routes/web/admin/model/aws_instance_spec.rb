# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AwsInstance" do
  include AdminModelSpecHelper

  before do
    @instance = create_aws_instance
    admin_account_setup_and_login
  end

  it "displays the AwsInstance instance page correctly" do
    click_link "AwsInstance"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsInstance"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AwsInstance #{@instance.ubid}"
  end
end
