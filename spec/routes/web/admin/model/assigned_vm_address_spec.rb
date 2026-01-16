# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AssignedVmAddress" do
  include AdminModelSpecHelper

  before do
    @instance = create_assigned_vm_address
    admin_account_setup_and_login
  end

  it "displays the AssignedVmAddress instance page correctly" do
    click_link "AssignedVmAddress"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AssignedVmAddress"

    click_link @instance.admin_label.to_s
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AssignedVmAddress #{@instance.ubid}"
  end
end
