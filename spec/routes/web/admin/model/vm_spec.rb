# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Vm" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm
    admin_account_setup_and_login
  end

  it "displays the Vm instance page correctly" do
    click_link "Vm"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Vm - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Vm #{@instance.ubid}"
  end
end
