# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "LocalVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_local_volume
    admin_account_setup_and_login
  end

  it "displays the LocalVolume instance page correctly" do
    click_link "LocalVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocalVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - LocalVolume #{@instance.ubid}"
  end
end
