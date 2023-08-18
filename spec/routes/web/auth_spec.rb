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
    verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-account.+?)"/)[1]

    visit verify_link
    expect(page.title).to eq("Ubicloud - Verify Account")

    click_button "Verify Account"
    expect(page.title).to eq("Ubicloud - #{Account[email: TEST_USER_EMAIL].projects.first.name} Dashboard")
  end

  it "can remember login" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    expect(DB[:account_remember_keys].first(id: account.id)).not_to be_nil
  end

  it "can reset password" do
    create_account

    visit "/login"
    click_link "Forgot your password?"

    fill_in "Email Address", with: TEST_USER_EMAIL

    click_button "Request Password Reset"

    expect(page).to have_content("An email has been sent to you with a link to reset the password for your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1
    reset_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/reset-password.+?)"/)[1]

    visit reset_link
    expect(page.title).to eq("Ubicloud - Reset Password")
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

      click_button "Log out"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can change email" do
      new_email = "new@example.com"
      visit "/account/change-login"

      fill_in "New Email Address", with: new_email

      click_button "Change Email"

      expect(page).to have_content("An email has been sent to you with a link to verify your login change")
      expect(Mail::TestMailer.deliveries.length).to eq 1
      verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

      visit verify_link
      expect(page.title).to eq("Ubicloud - Verify New Email")
    end
  end
end
