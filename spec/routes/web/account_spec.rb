# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "account" do
  it "can not access without login" do
    visit "/account"

    expect(page.title).to eq("Ubicloud - Login")
  end

  describe "authenticated" do
    before do
      create_account
      login
    end

    it "show password change page" do
      visit "/account"

      expect(page.title).to eq("Ubicloud - Change Password")
      expect(page).to have_content "Change Password"
    end

    it "show 2FA manage page" do
      visit "/account/multifactor-manage"

      expect(page.title).to eq("Ubicloud - Multifactor Authentication")
    end
  end
end
