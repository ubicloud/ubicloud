# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "ApiKey" do
  include AdminModelSpecHelper

  before do
    @instance = create_api_key
    admin_account_setup_and_login
  end

  it "displays the ApiKey instance page correctly" do
    click_link "ApiKey"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ApiKey"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - ApiKey #{@instance.ubid}"
  end
end
