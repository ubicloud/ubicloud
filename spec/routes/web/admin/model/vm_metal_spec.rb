# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmMetal" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_metal
    admin_account_setup_and_login
  end

  it "displays the VmMetal instance page correctly" do
    click_link "VmMetal"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmMetal"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmMetal #{@instance.ubid}"
  end
end
