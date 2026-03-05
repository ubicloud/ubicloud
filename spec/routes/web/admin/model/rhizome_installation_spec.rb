# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "RhizomeInstallation" do
  include AdminModelSpecHelper

  before do
    @instance = create_rhizome_installation
    admin_account_setup_and_login
  end

  it "displays the RhizomeInstallation instance page correctly" do
    click_link "RhizomeInstallation"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RhizomeInstallation"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RhizomeInstallation #{@instance.ubid}"
  end
end
