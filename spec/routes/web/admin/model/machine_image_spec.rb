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
    expect(page.title).to eq "Ubicloud Admin - MachineImage - Browse"

    click_link @instance.admin_label, match: :first
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImage #{@instance.ubid}"
  end

  it "supports make_public and make_private actions" do
    fill_in "UBID or UUID", with: @instance.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - MachineImage #{@instance.ubid}"

    expect(@instance.visible).to be false
    click_link "Make Public"
    click_button "Make Public"
    expect(page).to have_flash_notice("Image is now public")
    expect(@instance.reload.visible).to be true

    click_link "Make Private"
    click_button "Make Private"
    expect(page).to have_flash_notice("Image is now private")
    expect(@instance.reload.visible).to be false
  end

  it "rejects make_public for encrypted images" do
    @instance.update(encrypted: true)
    fill_in "UBID or UUID", with: @instance.ubid
    click_button "Show Object"

    click_link "Make Public"
    expect { click_button "Make Public" }.to raise_error(RuntimeError, "Cannot make encrypted image public")
  end

  it "supports decommission action" do
    fill_in "UBID or UUID", with: @instance.ubid
    click_button "Show Object"
    expect(page.title).to eq "Ubicloud Admin - MachineImage #{@instance.ubid}"

    expect(@instance.state).to eq "available"
    click_link "Decommission"
    click_button "Decommission"
    expect(page).to have_flash_notice("Image decommissioned")
    expect(@instance.reload.state).to eq "decommissioned"
  end
end
