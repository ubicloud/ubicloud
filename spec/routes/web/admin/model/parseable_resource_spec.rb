# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ParseableResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_parseable_resource
    admin_account_setup_and_login
  end

  it "displays the ParseableResource instance page correctly" do
    click_link "ParseableResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ParseableResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ParseableResource #{@instance.ubid}"
  end
end
