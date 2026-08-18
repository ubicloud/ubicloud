# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "JwtIssuer" do
  include AdminModelSpecHelper

  before do
    @instance = create_jwt_issuer
    admin_account_setup_and_login
  end

  it "displays the JwtIssuer instance page correctly" do
    click_link "JwtIssuer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - JwtIssuer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - JwtIssuer #{@instance.ubid}"
  end
end
