# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VhostBlockBackend" do
  include AdminModelSpecHelper

  before do
    @instance = create_vhost_block_backend
    admin_account_setup_and_login
  end

  it "displays the VhostBlockBackend instance page correctly" do
    click_link "VhostBlockBackend"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VhostBlockBackend"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VhostBlockBackend #{@instance.ubid}"
  end
end
