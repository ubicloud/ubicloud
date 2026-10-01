# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "DetachableVolume" do
  include AdminModelSpecHelper

  before do
    @instance = create_detachable_volume
    admin_account_setup_and_login
  end

  it "displays the DetachableVolume instance page correctly" do
    click_link "DetachableVolume"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DetachableVolume"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - DetachableVolume #{@instance.ubid}"
  end
end
