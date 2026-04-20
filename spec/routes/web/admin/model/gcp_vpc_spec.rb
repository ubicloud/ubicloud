# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GcpVpc" do
  include AdminModelSpecHelper

  before do
    @instance = create_gcp_vpc
    admin_account_setup_and_login
  end

  it "displays the GcpVpc instance page correctly" do
    click_link "GcpVpc"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GcpVpc"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GcpVpc #{@instance.ubid}"
  end
end
