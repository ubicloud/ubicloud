# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GcpVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_gcp_volume
    admin_account_setup_and_login
  end

  it "displays the GcpVolume instance page correctly" do
    click_link "GcpVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GcpVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GcpVolume #{@instance.ubid}"
  end
end
