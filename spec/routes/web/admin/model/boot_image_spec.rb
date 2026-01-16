# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "BootImage" do
  include AdminModelSpecHelper

  before do
    @instance = create_boot_image
    admin_account_setup_and_login
  end

  it "displays the BootImage instance page correctly" do
    click_link "BootImage"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BootImage"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - BootImage #{@instance.ubid}"
  end
end
