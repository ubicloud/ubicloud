# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  it "dispatches requests from Clover to CloverAdmin if host starts with admin." do
    visit "/"
    expect(page.title).to eq "Ubicloud Admin"
    expect(page).to have_content "admin.ubicloud.com"
  end
end
