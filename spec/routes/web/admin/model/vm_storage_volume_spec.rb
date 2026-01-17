# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmStorageVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_storage_volume
    admin_account_setup_and_login
  end

  it "displays the VmStorageVolume instance page correctly" do
    click_link "VmStorageVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmStorageVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmStorageVolume #{@instance.ubid}"
  end
end
