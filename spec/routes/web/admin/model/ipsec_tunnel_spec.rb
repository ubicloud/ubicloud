# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "IpsecTunnel" do
  include AdminModelSpecHelper

  before do
    @instance = create_ipsec_tunnel
    admin_account_setup_and_login
  end

  it "displays the IpsecTunnel instance page correctly" do
    click_link "IpsecTunnel"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - IpsecTunnel"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - IpsecTunnel #{@instance.ubid}"
  end
end
