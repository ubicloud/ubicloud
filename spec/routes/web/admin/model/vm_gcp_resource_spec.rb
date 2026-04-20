# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VmGcpResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm_gcp_resource
    admin_account_setup_and_login
  end

  it "displays the VmGcpResource instance page correctly" do
    click_link "VmGcpResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmGcpResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VmGcpResource #{@instance.ubid}"
  end
end
