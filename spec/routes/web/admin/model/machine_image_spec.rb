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

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MachineImage #{@instance.ubid}"
  end

  it "can make an unencrypted image public" do
    @instance.update(encrypted: false)
    expect(@instance.visible).to be false

    visit "/model/MachineImage/#{@instance.ubid}/make_public"
    expect(page.status_code).to eq 200

    click_button "Make Public"
    expect(page.status_code).to eq 200
    expect(page).to have_content("Image marked as public")
    expect(@instance.reload.visible).to be true
  end

  it "rejects making an encrypted image public" do
    @instance.update(encrypted: true)

    visit "/model/MachineImage/#{@instance.ubid}/make_public"
    expect(page.status_code).to eq 200

    expect { click_button "Make Public" }.to raise_error(RuntimeError, /Cannot make an encrypted image public/)
  end

  it "can make an image private" do
    @instance.update(visible: true)

    visit "/model/MachineImage/#{@instance.ubid}/make_private"
    expect(page.status_code).to eq 200

    click_button "Make Private"
    expect(page.status_code).to eq 200
    expect(page).to have_content("Image marked as private")
    expect(@instance.reload.visible).to be false
  end

  it "can decommission an image" do
    expect(@instance.state).to eq "available"

    visit "/model/MachineImage/#{@instance.ubid}/decommission"
    expect(page.status_code).to eq 200

    click_button "Decommission"
    expect(page.status_code).to eq 200
    expect(page).to have_content("Image decommissioned")
    expect(@instance.reload.state).to eq "decommissioned"
  end
end
