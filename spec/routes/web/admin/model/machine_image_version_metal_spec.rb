# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MachineImageVersionMetal" do
  include AdminModelSpecHelper

  before do
    @instance = create_machine_image_version_metal
    admin_account_setup_and_login
  end

  it "displays the MachineImageVersionMetal instance page correctly" do
    click_link "MachineImageVersionMetal"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageVersionMetal"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageVersionMetal #{@instance.ubid}"
  end
end
