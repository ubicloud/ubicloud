# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Cert" do
  include AdminModelSpecHelper

  before do
    @instance = create_cert
    admin_account_setup_and_login
  end

  it "displays the Cert instance page correctly" do
    click_link "Cert"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Cert"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Cert #{@instance.ubid}"
  end
end
