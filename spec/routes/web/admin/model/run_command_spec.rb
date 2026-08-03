# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "RunCommand" do
  include AdminModelSpecHelper

  before do
    @instance = create_run_command
    admin_account_setup_and_login
  end

  it "displays the RunCommand instance page correctly" do
    click_link "RunCommand"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RunCommand"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - RunCommand #{@instance.ubid}"
  end
end
