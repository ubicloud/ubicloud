# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "DnsZone" do
  include AdminModelSpecHelper

  before do
    @instance = create_dns_zone
    admin_account_setup_and_login
  end

  it "displays the DnsZone instance page correctly" do
    click_link "DnsZone"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsZone"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsZone #{@instance.ubid}"
  end
end
