# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Nic" do
  include AdminModelSpecHelper

  before do
    @instance = create_nic
    admin_account_setup_and_login
  end

  it "displays the Nic instance page correctly" do
    click_link "Nic"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Nic"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Nic #{@instance.ubid}"
  end
end
