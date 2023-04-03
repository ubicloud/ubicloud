# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "/vm" do
  it "has a page title" do
    visit "/vm"
    expect(page.title).to eq("Ubicloud - Login")
  end
end
