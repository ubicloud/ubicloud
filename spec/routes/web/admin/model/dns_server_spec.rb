# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "DnsServer" do
  include AdminModelSpecHelper

  before do
    @instance = create_dns_server
    admin_account_setup_and_login
  end

  it "displays the DnsServer instance page correctly" do
    click_link "DnsServer"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsServer"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsServer #{@instance.ubid}"
  end
end
