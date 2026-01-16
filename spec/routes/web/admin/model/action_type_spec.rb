# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ActionType" do
  include AdminModelSpecHelper

  before do
    @instance = create_action_type
    admin_account_setup_and_login
  end

  it "displays the ActionType instance page correctly" do
    click_link "ActionType"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ActionType"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ActionType #{@instance.ubid}"
  end
end
