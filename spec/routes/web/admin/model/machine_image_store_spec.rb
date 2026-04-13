# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MachineImageStore" do
  include AdminModelSpecHelper

  before do
    @instance = create_machine_image_store
    admin_account_setup_and_login
  end

  it "displays the MachineImageStore instance page correctly" do
    click_link "MachineImageStore"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageStore"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImageStore #{@instance.ubid}"
  end
end
