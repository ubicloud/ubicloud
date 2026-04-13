# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MachineImage" do
  include AdminModelSpecHelper

  before do
    @instance = create_machine_image
    admin_account_setup_and_login
  end

  it "displays the MachineImage instance page correctly" do
    click_link "MachineImage"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImage"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImage #{@instance.ubid}"
  end
end
