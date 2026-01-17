# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "StorageDevice" do
  include AdminModelSpecHelper

  before do
    @instance = create_storage_device
    admin_account_setup_and_login
  end

  it "displays the StorageDevice instance page correctly" do
    click_link "StorageDevice"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - StorageDevice"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - StorageDevice #{@instance.ubid}"
  end
end
