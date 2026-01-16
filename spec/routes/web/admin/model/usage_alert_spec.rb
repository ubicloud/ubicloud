# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "UsageAlert" do
  include AdminModelSpecHelper

  before do
    @instance = create_usage_alert
    admin_account_setup_and_login
  end

  it "displays the UsageAlert instance page correctly" do
    click_link "UsageAlert"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - UsageAlert"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - UsageAlert #{@instance.ubid}"
  end
end
