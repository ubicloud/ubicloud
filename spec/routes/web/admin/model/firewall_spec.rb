# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Firewall" do
  include AdminModelSpecHelper

  before do
    @instance = create_firewall
    admin_account_setup_and_login
  end

  it "displays the Firewall instance page correctly" do
    click_link "Firewall"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Firewall - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Firewall #{@instance.ubid}"
  end
end
