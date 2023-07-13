# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "auth" do
  it "redirects root to login" do
    visit "/"

    expect(page).to have_current_path("/login")
  end

  it "can not login new account without verification" do
    visit "/create-account"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(Mail::TestMailer.deliveries.length).to eq 1

    expect(page.title).to eq("Ubicloud - Login")

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Resend Verification")
  end

  it "can create new account and verify it" do
    visit "/create-account"
    fill_in "Full Name", with: "John Doe"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(page).to have_content("An email has been sent to you with a link to verify your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1
    verify_link = Mail::TestMailer.deliveries.first.body.match(/(\/verify-account.+)\s\s/)[1]

    visit verify_link
    expect(page.title).to eq("Ubicloud - Verify Account")

    click_button "Verify Account"
    expect(page.title).to eq("Ubicloud - Dashboard")
  end

  it "can remember login" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Dashboard")
    expect(DB[:account_remember_keys].first(id: account.id)).not_to be_nil
  end

  describe "authenticated" do
    before do
      create_account
      login
    end

    it "redirects root to dashboard" do
      visit "/dashboard"

      expect(page).to have_current_path("/dashboard")
    end

    it "can logout" do
      visit "/dashboard"

      within find_by_id("desktop-menu") do
        click_button "Log out"
      end

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
