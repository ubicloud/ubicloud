# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Page" do
  include AdminModelSpecHelper

  before do
    @instance = create_page
    admin_account_setup_and_login
  end

  it "displays the Page instance page correctly" do
    click_link "Page"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Page"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Page #{@instance.ubid}"
  end
end
