# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PciDevice" do
  include AdminModelSpecHelper

  before do
    @instance = create_pci_device
    admin_account_setup_and_login
  end

  it "displays the PciDevice instance page correctly" do
    click_link "PciDevice"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PciDevice"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PciDevice #{@instance.ubid}"
  end
end
