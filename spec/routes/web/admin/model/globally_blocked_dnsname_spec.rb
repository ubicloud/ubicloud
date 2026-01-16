# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GloballyBlockedDnsname" do
  include AdminModelSpecHelper

  before do
    @instance = create_globally_blocked_dnsname
    admin_account_setup_and_login
  end

  it "displays the GloballyBlockedDnsname instance page correctly" do
    click_link "GloballyBlockedDnsname"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GloballyBlockedDnsname"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GloballyBlockedDnsname #{@instance.ubid}"
  end
end
