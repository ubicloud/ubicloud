# frozen_string_literal: true

require_relative "spec_helper"
require "webauthn/fake_client"

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
      visit "/account/change-password"

      expect(page.title).to eq("Ubicloud - Change Password")
      expect(page).to have_content "Change Password"
    end

    [true, false].each do |clear_last_password_entry|
      it "allows setting up#{", authenticating with, unlocking," if clear_last_password_entry} and removing OTP authentication when password entry is #{"not " unless clear_last_password_entry}required" do
        visit "/clear-last-password-entry" if clear_last_password_entry

        visit "/account/multifactor-manage"
        expect(page.title).to eq("Ubicloud - Multifactor Authentication")

        click_link "Enable"
        expect(page.title).to eq("Ubicloud - Setup One-Time Password")
        totp = ROTP::TOTP.new(find_by_id("otp-secret").text)
        fill_in "Authentication Code", with: totp.now
        fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        click_button "Enable One-Time Password Authentication"
        expect(page).to have_flash_notice "One-time password authentication is now setup, please make note of your recovery codes"
        expect(page.title).to eq("Ubicloud - Recovery Codes")

        if clear_last_password_entry
          DB[:account_otp_keys].update(last_use: Sequel.date_sub(Sequel::CURRENT_TIMESTAMP, seconds: 4600))
          click_button "Log out"
          visit "/login"
          fill_in "Email Address", with: TEST_USER_EMAIL
          click_button "Sign in"
          fill_in "Password", with: TEST_USER_PASSWORD
          click_button "Sign in"
          expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
          fill_in "Authentication Code", with: totp.now
          click_button "Authenticate Using One-Time Password"
          expect(page).to have_flash_notice("You have been logged in")

          DB[:account_otp_keys].update(last_use: Sequel.date_sub(Sequel::CURRENT_TIMESTAMP, seconds: 4600))
          click_button "Log out"
          visit "/login"
          fill_in "Email Address", with: TEST_USER_EMAIL
          click_button "Sign in"
          fill_in "Password", with: TEST_USER_PASSWORD
          click_button "Sign in"
          6.times do
            expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
            fill_in "Authentication Code", with: totp.now + "1"
            click_button "Authenticate Using One-Time Password"
          end
          expect(page).to have_flash_error("TOTP authentication code use locked out due to numerous failures")
          expect(Mail::TestMailer.deliveries.length).to eq 1
          expect(Mail::TestMailer.deliveries.first.subject).to eq "Ubicloud Account One-Time Password Authentication Locked Out"

          2.times do
            expect(page.title).to eq("Ubicloud - One-Time Password Unlock")
            fill_in "Authentication Code", with: totp.now
            click_button "Authenticate Using One-Time Password to Unlock"
            expect(page).to have_flash_notice("One-Time Password successful authentication, more successful authentication needed to unlock")
            expect(page.title).to eq("Ubicloud - One-Time Password Unlock Not Available")
            DB[:account_otp_unlocks].update(next_auth_attempt_after: Sequel.date_sub(Sequel::CURRENT_TIMESTAMP, seconds: 200))
            visit page.current_path
          end

          expect(page.title).to eq("Ubicloud - One-Time Password Unlock")
          fill_in "Authentication Code", with: totp.now
          click_button "Authenticate Using One-Time Password to Unlock"
          expect(page).to have_flash_notice("One-Time Password authentication unlocked")
          expect(Mail::TestMailer.deliveries.length).to eq 2
          expect(Mail::TestMailer.deliveries.last.subject).to eq "Ubicloud Account One-Time Password Authentication Unlocked"

          DB[:account_otp_keys].update(last_use: Sequel.date_sub(Sequel::CURRENT_TIMESTAMP, seconds: 4600))
          expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
          fill_in "Authentication Code", with: totp.now
          click_button "Authenticate Using One-Time Password"
          expect(page).to have_flash_notice("You have been logged in")

          visit "/clear-last-password-entry"
        end

        visit "/account/multifactor-manage"
        click_link "Disable"
        expect(page.title).to eq("Ubicloud - Disable One-Time Password")
        fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        click_button "Disable One-Time Password Authentication"
        expect(page).to have_flash_notice "One-time password authentication has been disabled"
      end

      it "allows setting up#{", authenticating," if clear_last_password_entry} and removing Webauthn authentication when password entry is #{"not " unless clear_last_password_entry}required" do
        webauthn_client = WebAuthn::FakeClient.new("http://www.example.com")
        2.times do |i|
          visit "/clear-last-password-entry" if clear_last_password_entry
          visit "/account/multifactor-manage"
          expect(page.title).to eq("Ubicloud - Multifactor Authentication")
          click_link "Add"
          expect(page.title).to eq("Ubicloud - Setup Security Key")
          challenge = JSON.parse(page.find_by_id("webauthn-setup-form")["data-credential-options"])["challenge"]
          fill_in "Key Name", with: "My Key #{i}"
          fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
          fill_in "webauthn-setup", with: webauthn_client.create(challenge: challenge).to_json, visible: false
          click_button "Setup Security Key"
          expect(page).to have_flash_notice "Security key is now setup, please make note of your recovery codes"
          expect(page.title).to eq("Ubicloud - Recovery Codes")
        end

        if clear_last_password_entry
          click_button "Log out"
          visit "/login"
          fill_in "Email Address", with: TEST_USER_EMAIL
          click_button "Sign in"
          fill_in "Password", with: TEST_USER_PASSWORD
          click_button "Sign in"
          expect(page.title).to eq("Ubicloud - 2FA - Security Keys")
          challenge = JSON.parse(page.find_by_id("webauthn-auth-form")["data-credential-options"])["challenge"]
          fill_in "webauthn_auth", with: webauthn_client.get(challenge: challenge).to_json, visible: false
          click_button "Authenticate Using Security Keys"
          expect(page).to have_flash_notice "You have been logged in"
        end

        DB.transaction(rollback: :always) do
          visit "/clear-last-password-entry" if clear_last_password_entry
          visit "/account/multifactor-manage"
          click_link "Remove"
          expect(page.title).to eq("Ubicloud - Remove Security Key")
          DB[:account_webauthn_keys].where(name: "My Key 1").delete
          fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
          choose "My Key 1"
          click_button "Remove Security Key"
        end

        expect(page).to have_flash_error "Error removing security key"
        expect(find_by_id("webauthn_remove-error").text).to eq "Invalid security key to remove"

        visit "/clear-last-password-entry" if clear_last_password_entry
        visit "/account/multifactor-manage"
        click_link "Remove"
        fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        choose "My Key 1"
        click_button "Remove Security Key"
        expect(page).to have_flash_notice "Security key has been removed"
      end
    end

    it "allows viewing and regenerating recovery codes" do
      visit "/account/multifactor-manage"
      click_link "Enable"
      totp = ROTP::TOTP.new(find_by_id("otp-secret").text)
      fill_in "Authentication Code", with: totp.now
      click_button "Enable One-Time Password Authentication"

      path = page.current_path
      visit "/clear-last-password-entry"
      visit path
      fill_in "Password", with: TEST_USER_PASSWORD
      click_button "View Authentication Recovery Codes"

      recovery_codes = DB[:account_recovery_codes].select_map(:code)
      expect(page.all("#recovery-codes-text div").map(&:text).sort).to eq recovery_codes.sort

      DB[:account_recovery_codes].delete
      visit path
      expect(page.all("#recovery-codes-text div").to_a).to be_empty
      click_button "Add Authentication Recovery Codes"

      recovery_codes = DB[:account_recovery_codes].select_map(:code)
      expect(page.all("#recovery-codes-text div").map(&:text).sort).to eq recovery_codes.sort
    end

    it "allows removing all multifactor authentication methods" do
      visit "/account/multifactor-manage"
      click_link "Enable"
      totp = ROTP::TOTP.new(find_by_id("otp-secret").text)
      fill_in "Authentication Code", with: totp.now
      click_button "Enable One-Time Password Authentication"
      expect(page).to have_flash_notice "One-time password authentication is now setup, please make note of your recovery codes"

      visit "/account/multifactor-manage"
      click_link "Add"
      webauthn_client = WebAuthn::FakeClient.new("http://www.example.com")
      challenge = JSON.parse(page.find_by_id("webauthn-setup-form")["data-credential-options"])["challenge"]
      fill_in "Key Name", with: "My Key"
      fill_in "webauthn-setup", with: webauthn_client.create(challenge: challenge).to_json, visible: false
      click_button "Setup Security Key"

      visit "/account/multifactor-manage"
      click_link "Remove All Multifactor Authentication Methods"
      expect(page.title).to eq("Ubicloud - Remove All Multifactor Authentication Methods")
      click_button "Remove All Multifactor Authentication Methods"
      expect(page).to have_flash_notice "All multifactor authentication methods have been disabled"
    end
  end
end
