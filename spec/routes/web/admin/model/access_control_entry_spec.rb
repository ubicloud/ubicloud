# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AccessControlEntry" do
  include AdminModelSpecHelper

  before do
    @instance = create_access_control_entry
    admin_account_setup_and_login
  end

  it "displays the AccessControlEntry instance page correctly" do
    click_link "AccessControlEntry"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AccessControlEntry"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AccessControlEntry #{@instance.ubid}"
  end
end
