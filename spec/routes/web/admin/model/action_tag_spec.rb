# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ActionTag" do
  include AdminModelSpecHelper

  before do
    @instance = create_action_tag
    admin_account_setup_and_login
  end

  it "displays the ActionTag instance page correctly" do
    click_link "ActionTag"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ActionTag"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ActionTag #{@instance.ubid}"
  end
end
