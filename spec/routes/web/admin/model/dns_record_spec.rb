# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "DnsRecord" do
  include AdminModelSpecHelper

  before do
    @instance = create_dns_record
    admin_account_setup_and_login
  end

  it "displays the DnsRecord instance page correctly" do
    click_link "DnsRecord"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsRecord"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DnsRecord #{@instance.ubid}"
  end
end
