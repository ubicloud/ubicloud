# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmHostSlice" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_host_slice
    admin_account_setup_and_login
  end

  it "displays the VmHostSlice instance page correctly" do
    click_link "VmHostSlice"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmHostSlice"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmHostSlice #{@instance.ubid}"
  end
end
