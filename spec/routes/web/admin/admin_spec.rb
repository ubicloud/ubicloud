# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  it "dispatches requests from Clover to CloverAdmin if host starts with admin." do
    visit "/"
    expect(page.body).to eq "admin.ubicloud.com"
  end
end
