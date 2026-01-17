# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "AssignedHostAddress" do
  include AdminModelSpecHelper

  before do
    @instance = create_assigned_host_address
    admin_account_setup_and_login
  end

  it "displays the AssignedHostAddress instance page correctly" do
    click_link "AssignedHostAddress"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AssignedHostAddress"

    click_link @instance.admin_label.to_s
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - AssignedHostAddress #{@instance.ubid}"
  end
end
