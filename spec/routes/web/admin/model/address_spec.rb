# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Address" do
  include AdminModelSpecHelper

  before do
    @instance = create_address
    admin_account_setup_and_login
  end

  it "displays the Address instance page correctly" do
    click_link "Address"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Address"

    click_link @instance.admin_label.to_s
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Address #{@instance.ubid}"
  end
end
