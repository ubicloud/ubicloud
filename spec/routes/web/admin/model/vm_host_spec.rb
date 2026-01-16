# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmHost" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_host
    admin_account_setup_and_login
  end

  it "displays the VmHost instance page correctly" do
    click_link "VmHost"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmHost - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmHost #{@instance.ubid}"
  end
end
