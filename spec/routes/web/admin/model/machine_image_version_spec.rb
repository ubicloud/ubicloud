# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MachineImageVersion" do
  include AdminModelSpecHelper

  before do
    @instance = create_machine_image_version
    admin_account_setup_and_login
  end

  it "displays the MachineImageVersion instance page correctly" do
    click_link "MachineImageVersion"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageVersion"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageVersion #{@instance.ubid}"
  end
end
