# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmInitScript" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_init_script
    admin_account_setup_and_login
  end

  it "displays the VmInitScript instance page correctly" do
    click_link "VmInitScript"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmInitScript"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmInitScript #{@instance.ubid}"
  end
end
