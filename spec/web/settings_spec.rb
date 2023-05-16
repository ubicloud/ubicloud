# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "settings" do
  it "can not access without login" do
    visit "/settings"

    expect(page.title).to eq("Ubicloud - Login")
  end

  describe "authenticated" do
    before do
      create_account
      login
    end

    it "show password change page" do
      visit "/settings"

      expect(page.title).to eq("Ubicloud - Settings")
      expect(page).to have_content "Change Password"
    end
  end
end
