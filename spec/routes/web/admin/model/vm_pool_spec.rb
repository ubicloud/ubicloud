# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmPool" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_pool
    admin_account_setup_and_login
  end

  it "displays the VmPool instance page correctly" do
    click_link "VmPool"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmPool"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmPool #{@instance.ubid}"
  end
end
