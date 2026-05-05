# frozen_string_literal: true

require_relative "spec_helper"
require "webauthn/fake_client"

RSpec.describe Clover, "auth" do
  def ip_hash(into = {})
    into["ip"] = "127.0.0.1"
    into
  end

  def audit_log_hash
    DB[:account_authentication_audit_log].select_hash(:message, :metadata)
  end

  before do
    expect(self).to receive(:audit_log_hash).and_call_original
  end

  it "redirects root to login" do
    visit "/"

    expect(page).to have_current_path("/login")
    expect(audit_log_hash).to eq({})
  end

  it "can not login new account without verification" do
    visit "/create-account"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Full Name", with: "John Doe"
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(Mail::TestMailer.deliveries.length).to eq 1

    expect(page.title).to eq("Ubicloud - Login")

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    expect(page).to have_flash_error("The account you tried to login with is currently awaiting verification")
    expect(page.title).to eq("Ubicloud - Resend Verification")
    expect(audit_log_hash).to eq({"create_account" => ip_hash})
  end

  it "can not create new account with invalid name" do
    visit "/create-account"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Full Name", with: "Click here http://example.com"
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(page.title).to eq("Ubicloud - Create Account")
    expect(Mail::TestMailer.deliveries.length).to eq 0
    expect(page).to have_content("Name must only contain letters, numbers, spaces, and hyphens and have max length 63.")
    expect(audit_log_hash).to eq({})
  end

  it "can not create new account with invalid email" do
    visit "/create-account"
    fill_in "Email Address", with: "\u1234@something.com"
    fill_in "Full Name", with: "test"
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    expect(EmailRenderer).to receive(:sendmail).and_raise(Net::SMTPSyntaxError, "501 5.1.3 Bad recipient address syntax")
    click_button "Create Account"

    expect(page.title).to eq("Ubicloud - Create Account")
    expect(Mail::TestMailer.deliveries.length).to eq 0
    expect(page).to have_flash_error("Invalid email address used")
    expect(audit_log_hash).to eq({})
  end

  it "can send email verification email again after 300 seconds" do
    visit "/create-account"
    fill_in "Full Name", with: "John Doe"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1

    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"

    expect(page).to have_flash_error("The account you tried to login with is currently awaiting verification")
    expect(page).to have_content("You need to wait at least 5 minutes before sending another verification email. If you did not receive the email, please check your spam folder.")

    DB[:account_verification_keys].update(email_last_sent: Time.now - 310)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    expect(page).to have_flash_error("The account you tried to login with is currently awaiting verification")

    DB.transaction(rollback: :always) do
      click_button "Send Verification Again"

      expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
      expect(Mail::TestMailer.deliveries.length).to eq 2
    end

    visit "/verify-account-resend"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Send Verification Again"

    expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
    expect(Mail::TestMailer.deliveries.length).to eq 3
    expect(audit_log_hash).to eq({"create_account" => ip_hash, "verify_account_email_resend" => ip_hash})
  end

  it "can create new account and verify it" do
    visit "/create-account"
    fill_in "Full Name", with: "John Doe"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    expect(page).to have_no_content "By using Ubicloud console you agree to our"
    click_button "Create Account"

    expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1
    verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-account.+?)"/)[1]

    visit verify_link
    expect(page.title).to eq("Ubicloud - Verify Account")

    click_button "Verify Account"
    expect(page.title).to eq("Ubicloud - Default Dashboard")
    expect(audit_log_hash).to eq({"create_account" => ip_hash, "verify_account" => ip_hash})
  end

  it "can not create new account without cloudflare turnstile key if turnstile usage enabled" do
    expect(Config).to receive(:cloudflare_turnstile_site_key).and_return("cf_site_key").thrice
    visit "/create-account"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Full Name", with: "Joe User"
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    click_button "Create Account"

    expect(page.title).to eq("Ubicloud - Create Account")
    expect(Mail::TestMailer.deliveries.length).to eq 0
    expect(page).to have_content("Could not create account. Please ensure JavaScript is enabled and access to Cloudflare is not blocked, then try again.")
    expect(audit_log_hash).to eq({})
  end

  it "can create new account and verify it when there are existing invitations" do
    p = Project.create(name: "Invited-project")
    subject_id = SubjectTag.create(project_id: p.id, name: "Admin").id
    AccessControlEntry.create(project_id: p.id, subject_id:, action_id: ActionType::NAME_MAP["Project:view"])
    inviter_id = Account.create(email: "test2@example.com", name: "").id
    p.add_invitation(email: TEST_USER_EMAIL, policy: "Admin", inviter_id:, expires_at: Time.now + 7 * 24 * 60 * 60)

    expect(Config).to receive(:managed_service).and_return(true).at_least(:once)
    expect(Config).to receive(:cloudflare_turnstile_site_key).and_return("1")
    visit "/create-account"
    expect(page.find(".cf-turnstile")["data-sitekey"]).to eq "1"
    expect(Config).to receive(:cloudflare_turnstile_site_key).and_return(nil).at_least(:once)
    fill_in "Full Name", with: "John Doe"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD
    expect(page).to have_content "By using Ubicloud console you agree to our"
    click_button "Create Account"

    expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1
    verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-account.+?)"/)[1]

    visit verify_link
    expect(page.title).to eq("Ubicloud - Verify Account")
    expect(Account.first(email: TEST_USER_EMAIL).default_project.name).to eq "Default"

    click_button "Verify Account"
    expect(page.title).to eq("Ubicloud - Projects")
    expect(page).to have_content "Project Invitations"
    expect(audit_log_hash).to eq({"create_account" => ip_hash, "verify_account" => ip_hash})
  end

  it "can remember login" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Default Dashboard")
    expect(DB[:account_remember_keys].first(id: account.id)).not_to be_nil
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "has correct current user when logged in via remember token" do
    create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Default Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    page.refresh
    expect(page.title).to eq("Ubicloud - Default Dashboard")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password"), "load_memory" => ip_hash})
  end

  it "can reset password" do
    create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    click_link "Forgot your password?"

    click_button "Request Password Reset"

    expect(page).to have_flash_notice("An email has been sent to you with a link to reset the password for your account")
    expect(Mail::TestMailer.deliveries.length).to eq 1
    reset_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/reset-password.+?)"/)[1]

    visit reset_link
    expect(page.title).to eq("Ubicloud - Reset Password")

    fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"
    fill_in "Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

    click_button "Reset Password"

    expect(page.title).to eq("Ubicloud - Login")

    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"

    click_button "Sign in"
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password"), "reset_password_request" => ip_hash, "reset_password" => ip_hash})
  end

  it "can not reset password if password disabled" do
    account = create_account
    DB[:account_password_hashes].where(id: account.id).delete

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    expect(page).to have_no_content("Forget your password?")

    visit "/reset-password-request"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Request Password Reset"

    expect(page).to have_flash_error(/Login with password is not enabled for this account.*/)
    expect(DB[:account_password_reset_keys].count).to eq 0
    expect(audit_log_hash).to eq({})
  end

  it "can login to an account when there are no omniauth_providers" do
    create_account(with_project: false)
    expect(Config).to receive(:omniauth_google_id).and_return(nil)
    expect(Config).to receive(:omniauth_github_id).and_return(nil)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Projects")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "can login to an account without projects" do
    create_account(with_project: false)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Projects")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "can not login with incorrect password" do
    create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD + "1"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in")
    expect(audit_log_hash).to eq({"login_failure" => ip_hash("reason" => "incorrect password")})
  end

  it "can not login if the account is suspended" do
    account = create_account
    account.suspend

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error(/Your account has been suspended.*/)
    expect(audit_log_hash).to eq({"login_failure" => ip_hash("reason" => "account suspended")})
  end

  it "can not login if the account is suspended via remember token" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Default Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    account.suspend
    page.refresh
    expect(page.title).to eq("Ubicloud - Login")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password"), "login_failure" => ip_hash("reason" => "account suspended")})
  end

  it "redirects to otp page if the otp is only 2FA method" do
    create_account(enable_otp: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "redirects to webauthn page if the webauthn is only 2FA method" do
    create_account(enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - Security Keys")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "shows 2FA method list if there are multiple 2FA methods" do
    create_account(enable_otp: true, enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Two-factor Authentication")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  it "shows enter recovery codes page" do
    create_account(enable_otp: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    click_link "Enter a recovery code"

    expect(page.title).to eq("Ubicloud - 2FA - Recovery Codes")
    expect(audit_log_hash).to eq({"login" => ip_hash("via" => "password")})
  end

  describe "authenticated" do
    before do
      create_account
      login
      DB[:account_authentication_audit_log].delete
    end

    it "redirects root to dashboard" do
      visit "/dashboard"

      expect(page).to have_current_path("/dashboard")
      expect(audit_log_hash).to eq({})
    end

    it "can logout" do
      visit "/dashboard"

      click_button "Log out"

      expect(page.title).to eq("Ubicloud - Login")
      expect(audit_log_hash).to eq({"logout" => ip_hash})
    end

    [true, false].each do |logged_in|
      it "can change email, verifying when #{"not " unless logged_in}logged in" do
        visit "/clear-last-password-entry" if logged_in
        new_email = "new@example.com"
        visit "/account/change-login"

        fill_in "New Email Address", with: new_email
        fill_in "Password", with: TEST_USER_PASSWORD if logged_in

        click_button "Change Email"

        expect(page).to have_flash_notice("An email has been sent to you with a link to verify your login change")
        expect(Mail::TestMailer.deliveries.length).to eq 1
        mail = Mail::TestMailer.deliveries.first
        expect(mail.to).to eq [new_email]
        verify_link = mail.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

        click_button "Log out" unless logged_in
        visit verify_link
        expect(page.title).to eq("Ubicloud - Verify New Email")
        expect(page).to have_content("Verify your new email") unless logged_in

        click_button "Click to Verify New Email"

        expect(page).to have_flash_notice "Your login change has been verified"
        if logged_in
          expect(page.title).to eq("Ubicloud - Default Dashboard")
          click_button "Log out"
        end

        expect(page.title).to eq("Ubicloud - Login")

        fill_in "Email Address", with: new_email
        click_button "Sign in"
        fill_in "Password", with: TEST_USER_PASSWORD

        click_button "Sign in"
        expect(page).to have_flash_notice "You have been logged in"
        expect(audit_log_hash).to eq({
          "change_login" => ip_hash,
          "login" => ip_hash("via" => "password"),
          "logout" => ip_hash,
          "verify_login_change" => ip_hash("new_login" => "new@example.com", "previous_login" => "user@example.com"),
          "verify_login_change_email" => ip_hash,
        })
      end
    end

    it "can create password for accounts that do not have a password" do
      DB[:account_password_hashes].delete
      visit "/account/change-password"
      expect(page.title).to eq("Ubicloud - Create Password")

      fill_in "New Password", with: "#{TEST_USER_PASSWORD}_new"
      fill_in "New Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Create Password"

      expect(page.title).to eq("Ubicloud - Change Password")

      click_button "Log out"

      expect(page.title).to eq("Ubicloud - Login")

      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Sign in"
      fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Sign in"
      expect(audit_log_hash).to eq({
        "login" => ip_hash("via" => "password"),
        "logout" => ip_hash,
        "change_password" => ip_hash,
      })
    end

    it "does not allow duplicate passwords" do
      # Update account_previous_password_hashes, which isn't done by default in the specs
      password_hash = Argon2::Password.new({
        t_cost: 1,
        m_cost: 5,
        secret: Config.clover_session_secret,
      }).create(TEST_USER_PASSWORD)
      DB[:account_previous_password_hashes].insert(account_id: Account.get(:id), password_hash:)

      visit "/account/change-password"
      passwords = [TEST_USER_PASSWORD]
      3.times do
        passwords.each do |password|
          fill_in "New Password", with: password
          fill_in "New Password Confirmation", with: password

          click_button "Change Password"
          expect(page.title).to eq("Ubicloud - Change Password")
          expect(page).to have_flash_error("There was an error changing your password")
          expect(page).to have_text(/invalid password, same as current password|Password cannot be the same as a previous password/)
        end

        new_password = passwords.last + "_new"
        passwords << new_password
        fill_in "New Password", with: new_password
        fill_in "New Password Confirmation", with: new_password
        click_button "Change Password"
        expect(page.title).to eq("Ubicloud - Change Password")
        expect(page).to have_flash_notice("Your password has been changed")
      end
      expect(audit_log_hash).to eq({"change_password" => ip_hash})
    end

    [true, false].each do |clear_last_password_entry|
      it "can change password when password entry is #{"not " unless clear_last_password_entry}required" do
        visit "/clear-last-password-entry" if clear_last_password_entry
        visit "/account/change-password"

        fill_in "Current Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        bad_pass = "aA0"
        fill_in "New Password", with: bad_pass
        fill_in "New Password Confirmation", with: bad_pass

        click_button "Change Password"

        expect(page.title).to eq("Ubicloud - Change Password")
        expect(page).to have_flash_error("There was an error changing your password")
        expect(page).to have_content("Password must have 8 characters minimum and contain at least one lowercase letter, one uppercase letter, and one digit.")

        new_pass = TEST_USER_EMAIL + "New0"
        fill_in "New Password", with: new_pass
        fill_in "New Password Confirmation", with: new_pass

        click_button "Change Password"
        expect(page).to have_flash_notice("Your password has been changed")

        click_button "Log out"

        expect(page.title).to eq("Ubicloud - Login")

        fill_in "Email Address", with: TEST_USER_EMAIL
        click_button "Sign in"
        fill_in "Password", with: new_pass

        click_button "Sign in"
        expect(page).to have_flash_notice("You have been logged in")
        expect(audit_log_hash).to eq({
          "login" => ip_hash("via" => "password"),
          "logout" => ip_hash,
          "change_password" => ip_hash,
        })
      end

      it "can close account when password entry is #{"not " unless clear_last_password_entry}required" do
        visit "/clear-last-password-entry" if clear_last_password_entry
        account = Account[email: TEST_USER_EMAIL]
        UsageAlert.create(project_id: account.projects.first.id, user_id: account.id, name: "test", limit: 100)

        visit "/account/close-account"

        fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        click_button "Close Account"

        expect(page.title).to eq("Ubicloud - Login")
        expect(page).to have_flash_notice("Your account has been closed")

        expect(Account[email: TEST_USER_EMAIL]).to be_nil
        expect(DB[:access_tag].where(hyper_tag_id: account.id).count).to eq 0
        expect(audit_log_hash).to eq({"close_account" => ip_hash})
      end
    end

    it "can not close account if the project has some resources" do
      vm = create_vm
      project = Account[email: TEST_USER_EMAIL].projects.first
      vm.update(project_id: project.id)

      visit "/account/close-account"

      click_button "Close Account"

      expect(page.title).to eq("Ubicloud - Close Account")
      expect(page).to have_flash_error("'Default' project has some resources. Delete all related resources first.")
      expect(audit_log_hash).to eq({})
    end

    it "show password change page" do
      visit "/account/change-password"

      expect(page.title).to eq("Ubicloud - Change Password")
      expect(page).to have_content "Change Password"
      expect(audit_log_hash).to eq({})
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
            expect(page.response_headers["refresh"]).to match(/\A1[012]\d\z/)
            expect(page).to have_content(/Deadline for next authentication: \d+ seconds/)
            expect(page).to have_content(/Page will automatically refresh when authentication is possible \(in \d+ seconds\)\./)
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
        if clear_last_password_entry
          expect(audit_log_hash).to eq({
            "login" => ip_hash("via" => "password"),
            "logout" => ip_hash,
            "otp_authentication_failure" => ip_hash,
            "otp_disable" => ip_hash,
            "otp_setup" => ip_hash,
            "otp_unlock_auth_success" => ip_hash,
            "two_factor_authentication" => ip_hash("via" => "totp"),
          })
        else
          expect(audit_log_hash).to eq({"otp_setup" => ip_hash, "otp_disable" => ip_hash})
        end
      end

      it "allows setting up#{", authenticating," if clear_last_password_entry} and removing Webauthn authentication when password entry is #{"not " unless clear_last_password_entry}required" do
        webauthn_client = WebAuthn::FakeClient.new("http://localhost:9292")
        2.times do |i|
          visit "/clear-last-password-entry" if clear_last_password_entry
          visit "/account/multifactor-manage"
          expect(page.title).to eq("Ubicloud - Multifactor Authentication")
          click_link "Add"
          expect(page.title).to eq("Ubicloud - Setup Security Key")
          challenge = JSON.parse(page.find_by_id("webauthn-setup-form")["data-credential-options"])["challenge"]
          fill_in "Key Name", with: "My Key #{i}"
          fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
          fill_in "webauthn-setup", with: webauthn_client.create(challenge:).to_json, visible: false
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
          fill_in "webauthn_auth", with: webauthn_client.get(challenge:).to_json, visible: false
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
        if clear_last_password_entry
          expect(audit_log_hash).to eq({
            "login" => ip_hash("via" => "password"),
            "logout" => ip_hash,
            "webauthn_setup" => ip_hash("key_name" => "My Key 1"),
            "webauthn_remove" => ip_hash("key_name" => "My Key 1"),
            "two_factor_authentication" => ip_hash("via" => "webauthn", "key_name" => "My Key 0"),
          })
        else
          expect(audit_log_hash).to eq({"webauthn_setup" => ip_hash("key_name" => "My Key 1"), "webauthn_remove" => ip_hash("key_name" => "My Key 1")})
        end
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
      expect(audit_log_hash).to eq({"otp_setup" => ip_hash, "add_recovery_codes" => ip_hash})
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
      webauthn_client = WebAuthn::FakeClient.new("http://localhost:9292")
      challenge = JSON.parse(page.find_by_id("webauthn-setup-form")["data-credential-options"])["challenge"]
      fill_in "Key Name", with: "My Key"
      fill_in "webauthn-setup", with: webauthn_client.create(challenge:).to_json, visible: false
      click_button "Setup Security Key"

      visit "/account/multifactor-manage"
      click_link "Remove All Multifactor Authentication Methods"
      expect(page.title).to eq("Ubicloud - Remove All Multifactor Authentication Methods")
      click_button "Remove All Multifactor Authentication Methods"
      expect(page).to have_flash_notice "All multifactor authentication methods have been disabled"
      expect(audit_log_hash).to eq({
        "otp_setup" => ip_hash,
        "webauthn_setup" => ip_hash("key_name" => "My Key"),
        "two_factor_disable" => ip_hash,
      })
    end
  end

  describe "social login" do
    def mock_provider(provider, email = TEST_USER_EMAIL, name: "John Doe", mock_config: true)
      expect(Config).to receive("omniauth_#{provider}_id").and_return("12345").at_least(:once) if mock_config
      OmniAuth.config.add_mock(provider, {
        provider:,
        uid: "123456790",
        info: {
          name:,
          email:,
        },
      })
    end

    let(:oidc_provider) do
      op = OidcProvider.create(
        display_name: "TestOIDC",
        client_id: "123",
        client_secret: "456",
        url: "http://example.com",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw",
      )
      op.add_allowed_domain("example.com")
      op
    end

    before do
      OmniAuth.config.logger = Logger.new(IO::NULL)
      OmniAuth.config.test_mode = true
    end

    [true, false].each do |locked_domain|
      it "can login via OIDC flow using separate login page#{" when domain is locked" if locked_domain}" do
        visit "/auth/#{OidcProvider.generate_ubid}"
        expect(page.status_code).to eq 404

        provider = oidc_provider
        provider.add_locked_domain(domain: "Example.com") if locked_domain
        omniauth_key = provider.ubid.to_sym

        visit "/auth/#{provider.ubid}"
        expect(page.status_code).to eq 200
        expect(page.title).to eq "Ubicloud - Login to TestOIDC via OIDC"

        OmniAuth.config.mock_auth[omniauth_key] = :invalid_credentials
        click_button "Login"

        expect(page.title).to eq("Ubicloud - Login")
        expect(page).to have_flash_error("There was an error logging in with the external provider")

        visit "/auth/#{provider.ubid}"
        OmniAuth.config.add_mock(omniauth_key, provider: provider.ubid, uid: "789",
          info: {email: "user@example.com"})
        click_button "Login"

        account = Account.first
        expect(account.email).to eq "user@example.com"
        expect(AccountIdentity.select_hash(:account_id, :provider)).to eq(account.id => provider.ubid)
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(page).to have_flash_notice("You have been logged in")
        expect(audit_log_hash).to eq({"login" => ip_hash("via" => "TestOIDC"), "create_account" => ip_hash("provider" => "TestOIDC")})
      end
    end

    it "cannot login to an account via password when domain is locked" do
      oidc_provider.add_locked_domain(domain: "Example.com")
      account = create_account
      visit "/login"
      fill_in "Email Address", with: account.email
      click_button "Sign in"
      fill_in "Password", with: TEST_USER_PASSWORD
      click_button "Sign in"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Login via username and password is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(audit_log_hash).to eq({"login_failure" => ip_hash("reason" => "locked domain", "via" => "password")})
    end

    it "disallow attempting to verify an account in a locked domain" do
      visit "/create-account"
      fill_in "Full Name", with: "John Doe"
      fill_in "Email Address", with: TEST_USER_EMAIL
      fill_in "Password", with: TEST_USER_PASSWORD
      fill_in "Password Confirmation", with: TEST_USER_PASSWORD
      expect(page).to have_no_content "By using Ubicloud console you agree to our"
      click_button "Create Account"

      expect(page).to have_flash_notice("An email has been sent to you with a link to verify your account")
      expect(Mail::TestMailer.deliveries.length).to eq 1
      verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-account.+?)"/)[1]

      oidc_provider.add_locked_domain(domain: "Example.com")
      visit verify_link
      click_button "Verify Account"
      expect(page).to have_flash_error("Verifying accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(Account.all).to eq []
      expect(audit_log_hash).to eq({
        "close_account" => ip_hash,
        "create_account" => ip_hash,
        "verify_account_failure" => ip_hash("reason" => "locked domain"),
      })
    end

    it "attempting to create an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "Example.com")

      visit "/create-account"
      fill_in "Email Address", with: TEST_USER_EMAIL
      fill_in "Full Name", with: "John Doe"
      fill_in "Password", with: TEST_USER_PASSWORD
      fill_in "Password Confirmation", with: TEST_USER_PASSWORD
      click_button "Create Account"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Creating accounts with a password is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(audit_log_hash).to eq({})
    end

    it "attempting to reset the password for an account in a locked domain redirects to required OIDC login page" do
      create_account

      visit "/login"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Sign in"
      click_link "Forgot your password?"
      click_button "Request Password Reset"

      expect(page).to have_flash_notice("An email has been sent to you with a link to reset the password for your account")
      expect(Mail::TestMailer.deliveries.length).to eq 1
      reset_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/reset-password.+?)"/)[1]

      oidc_provider.add_locked_domain(domain: "Example.com")
      visit reset_link
      fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"
      fill_in "Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Reset Password"

      expect(page).to have_flash_error("Resetting passwords is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(audit_log_hash).to eq({
        "reset_password_request" => ip_hash,
        "reset_password_failure" => ip_hash("reason" => "locked domain"),
      })
    end

    it "requesting a password reset for an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "Example.com")

      create_account

      visit "/reset-password-request"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Request Password Reset"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Resetting passwords is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(audit_log_hash).to eq({"reset_password_request_failure" => ip_hash("reason" => "locked domain")})
    end

    it "attempting to unlock an account in a locked domain redirects to required OIDC login page" do
      account = create_account
      DB[:account_lockouts].insert(id: account.id, key: SecureRandom.urlsafe_base64(32))

      visit "/login"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Sign in"
      click_button "Request Account Unlock"

      expect(page).to have_flash_notice("An email has been sent to you with a link to unlock your account")
      expect(Mail::TestMailer.deliveries.length).to eq 1
      unlock_link = Mail::TestMailer.deliveries.first.body.match(/(\/unlock-account[^ ]+)/)[1]

      oidc_provider.add_locked_domain(domain: "Example.com")
      visit unlock_link
      click_button "Unlock Account"

      expect(page).to have_flash_error("Unlocking accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(audit_log_hash).to eq({
        "unlock_account_request" => ip_hash,
        "unlock_account_failure" => ip_hash("reason" => "locked domain"),
      })
    end

    it "requesting an account unlock for an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "Example.com")

      account = create_account
      DB[:account_lockouts].insert(id: account.id, key: SecureRandom.urlsafe_base64(32))

      visit "/login"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Sign in"
      click_button "Request Account Unlock"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Unlocking accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(audit_log_hash).to eq({"unlock_account_request_failure" => ip_hash("reason" => "locked domain")})
    end

    it "cannot login to an account via an omniauth provider when domain is locked to a different provider" do
      provider = OidcProvider.create(
        display_name: "TestOIDC2",
        client_id: "123",
        client_secret: "456",
        url: "http://example.com",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw",
      )
      provider.add_allowed_domain("example.com")

      visit "/auth/#{provider.ubid}"
      OmniAuth.config.add_mock(provider.ubid.to_sym, provider: provider.ubid, uid: "789",
        info: {email: "user@example.com"})
      click_button "Login"

      account = Account.first
      expect(account.email).to eq "user@example.com"
      expect(AccountIdentity.select_hash(:account_id, :provider)).to eq(account.id => provider.ubid)

      click_button "Log out"
      oidc_provider.add_locked_domain(domain: "Example.com")

      visit "/auth/#{provider.ubid}"
      click_button "Login"
      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Login via TestOIDC2 is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(audit_log_hash).to eq({
        "create_account" => ip_hash("provider" => "TestOIDC2"),
        "logout" => ip_hash,
        "login" => ip_hash("via" => "TestOIDC2"),
        "login_failure" => ip_hash("reason" => "locked domain", "provider" => "TestOIDC2"),
      })
    end

    it "cannot create account via an omniauth provider when domain is locked to a different provider" do
      oidc_provider.add_locked_domain(domain: "Example.com")
      provider = OidcProvider.create(
        display_name: "TestOIDC2",
        client_id: "123",
        client_secret: "456",
        url: "http://example.com",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw",
      )

      visit "/auth/#{provider.ubid}"
      OmniAuth.config.add_mock(provider.ubid.to_sym, provider: provider.ubid, uid: "789",
        info: {email: "user@example.com"})
      click_button "Login"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Creating an account via authentication through TestOIDC2 is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(Account.all).to eq []
      expect(AccountIdentity.all).to eq []
      expect(audit_log_hash).to eq({})
    end

    it "shows error message if attempting to create an account where social login has no email" do
      mock_provider(:github, nil)

      visit "/login"
      click_button "GitHub"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error(/Social login is only allowed if social login provider provides email/)
      expect(audit_log_hash).to eq({})
    end

    it "can create new account even if social account doesn't have a name" do
      mock_provider(:github, name: nil)

      visit "/login"
      click_button "GitHub"

      expect(Account[email: TEST_USER_EMAIL].name).to eq "user"
      expect(audit_log_hash).to eq({"create_account" => ip_hash("provider" => "GitHub"), "login" => ip_hash("via" => "GitHub")})
    end

    it "can create new account even if social account has a name that isn't a valid Ubicloud name" do
      mock_provider(:github, name: "123Foo..\u1234Bar")

      visit "/login"
      click_button "GitHub"

      expect(Account[email: TEST_USER_EMAIL].name).to eq "Foo \u1234Bar"
      expect(audit_log_hash).to eq({"create_account" => ip_hash("provider" => "GitHub"), "login" => ip_hash("via" => "GitHub")})
    end

    it "can create new account even if social account has a name is too long" do
      mock_provider(:github, name: "F" * 100)

      visit "/login"
      click_button "GitHub"

      expect(Account[email: TEST_USER_EMAIL].name).to eq("F" * 63)
      expect(audit_log_hash).to eq({"create_account" => ip_hash("provider" => "GitHub"), "login" => ip_hash("via" => "GitHub")})
    end

    it "can create new account even if name for social login cannot be determined" do
      email = ".@example.com"
      mock_provider(:github, email, name: nil)

      visit "/login"
      click_button "GitHub"

      expect(Account[email:].name).to eq "Unknown"
      expect(audit_log_hash).to eq({"create_account" => ip_hash("provider" => "GitHub"), "login" => ip_hash("via" => "GitHub")})
    end

    it "can create new account" do
      mock_provider(:github)

      visit "/login"
      click_button "GitHub"

      account = Account[email: TEST_USER_EMAIL]
      expect(account).not_to be_nil
      expect(account.identities_dataset.first(provider: "github", uid: "123456790")).not_to be_nil
      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Default Dashboard")
      expect(audit_log_hash).to eq({"create_account" => ip_hash("provider" => "GitHub"), "login" => ip_hash("via" => "GitHub")})
    end

    it "can login existing account" do
      mock_provider(:google)
      account = create_account
      account.add_identity(provider: "google", uid: "123456790")

      visit "/login"
      click_button "Google"

      expect(Account.count).to eq(1)
      expect(AccountIdentity.count).to eq(1)
      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Default Dashboard")
      expect(audit_log_hash).to eq({"login" => ip_hash("via" => "Google")})
    end

    it "can login existing account after its email has been changed" do
      mock_provider(:google)
      account = create_account
      account.add_identity(provider: "google", uid: "123456790")
      account.update(email: "renamed@example.com")
      account.projects.first.update(name: "Renamed")
      create_account("user@example.com")

      visit "/login"
      click_button "Google"

      expect(page.title).to eq("Ubicloud - Renamed Dashboard")
      expect(audit_log_hash).to eq({"login" => ip_hash("via" => "Google")})
    end

    it "can not login existing account before linking it" do
      mock_provider(:github)
      create_account

      visit "/login"
      click_button "GitHub"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error(/There is already an account with this email address.*/)
      expect(audit_log_hash).to eq({"login_failure" => ip_hash("reason" => "unlinked existing account", "provider" => "GitHub")})
    end

    describe "authenticated" do
      let(:account) { create_account }

      before do
        login(account.email)
        DB[:account_authentication_audit_log].delete
      end

      it "can connect and disconnect existing account to OIDC provider" do
        provider = oidc_provider
        omniauth_key = provider.ubid.to_sym

        visit "/account/login-method/oidc"
        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("No valid OIDC provider with that ID")

        visit "/account/login-method"
        within "#login-method-connect-oidc" do
          fill_in "OIDC Provider ID", with: provider.ubid
          click_button "Connect"
        end

        expect(AccountIdentity).to be_empty

        OmniAuth.config.mock_auth[omniauth_key] = :invalid_credentials
        click_button "Connect"

        expect(AccountIdentity).to be_empty
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(page).to have_flash_error("There was an error logging in with the external provider")

        visit "/account/login-method"
        within "#login-method-connect-oidc" do
          fill_in "OIDC Provider ID", with: provider.ubid
          click_button "Connect"
        end

        OmniAuth.config.add_mock(omniauth_key, provider: provider.ubid, uid: "789",
          info: {email: account.email})
        click_button "Connect"

        expect(AccountIdentity.select_hash(:account_id, :provider)).to eq(account.id => provider.ubid)
        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("You have successfully connected your account with TestOIDC.")

        within "#login-method-disconnect-oidc-#{provider.ubid}" do
          click_button "Disconnect"
        end

        expect(AccountIdentity).to be_empty
        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("Your account has been disconnected from TestOIDC")
        expect(audit_log_hash).to eq({
          "connect_provider" => ip_hash("provider" => "TestOIDC"),
          "disconnect_provider" => ip_hash("provider" => "TestOIDC"),
        })
      ensure
        OmniAuth.config.mock_auth[omniauth_key] = nil
      end

      [true, false].each do |locked_domain|
        it "can login via OIDC flow with already connected account using normal login page#{" when domain is locked" if locked_domain}" do
          omniauth_key = oidc_provider.ubid.to_sym
          oidc_provider.add_locked_domain(domain: "Example.com") if locked_domain
          AccountIdentity.create(account_id: Account.first.id, provider: oidc_provider.ubid, uid: "789")
          OmniAuth.config.add_mock(omniauth_key, provider: oidc_provider.ubid, uid: "789",
            info: {email: "user@example.com"})
          click_button "Log out"

          fill_in "Email Address", with: TEST_USER_EMAIL
          click_button "Sign in"
          expect(page).to have_content("Password")
          expect(page).to have_content("Or login with:")
          click_button "TestOIDC"

          expect(page.title).to eq("Ubicloud - Default Dashboard")
          expect(page).to have_flash_notice("You have been logged in")
          expect(audit_log_hash).to eq({
            "login" => ip_hash("via" => "TestOIDC"),
            "logout" => ip_hash,
          })
        end

        it "can login via OIDC flow with already connected account using normal login page when account does not have password#{" when domain is locked" if locked_domain}" do
          omniauth_key = oidc_provider.ubid.to_sym
          oidc_provider.add_locked_domain(domain: "Example.com") if locked_domain
          account_id = Account.first.id
          AccountIdentity.create(account_id:, provider: oidc_provider.ubid, uid: "789")
          AccountIdentity.create(account_id:, provider: "google", uid: "123")
          mock_provider(:google, "uSer@example.com")
          OmniAuth.config.add_mock(omniauth_key, provider: oidc_provider.ubid, uid: "789",
            info: {email: "user@example.com"})
          DB[:account_password_hashes].delete
          click_button "Log out"

          fill_in "Email Address", with: TEST_USER_EMAIL
          click_button "Sign in"
          expect(page).to have_no_content("Password")
          expect(page).to have_content("Login with:")
          expect(page).to have_content("Google")
          click_button "TestOIDC"

          expect(page.title).to eq("Ubicloud - Default Dashboard")
          expect(page).to have_flash_notice("You have been logged in")
          expect(audit_log_hash).to eq({
            "login" => ip_hash("via" => "TestOIDC"),
            "logout" => ip_hash,
          })
        end
      end

      it "can login via OIDC flow with with OIDC groups" do
        oidc_provider.update(group_prefix: "foo-")
        omniauth_key = oidc_provider.ubid.to_sym
        AccountIdentity.create(account_id: Account.first.id, provider: oidc_provider.ubid, uid: "789")
        OmniAuth.config.add_mock(omniauth_key, provider: oidc_provider.ubid, uid: "789",
          info: {email: "user@example.com", groups: %w[group1 group2]})
        click_button "Log out"

        fill_in "Email Address", with: TEST_USER_EMAIL
        click_button "Sign in"
        expect(page).to have_content("Password")
        expect(page).to have_content("Or login with:")
        expect(Clog).to receive(:emit).with("OIDC groups login", oidc_groups_login: {groups: %w[group1 group2], group_prefix: "foo-"})
        click_button "TestOIDC"

        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(page).to have_flash_notice("You have been logged in")

        project = Project.first
        visit project.path
        click_link "View Audit Logs"
        expect(page.title).to eq("Ubicloud - Default - Audit Log")

        AccessControlEntry.dataset.destroy
        page.refresh
        expect(page.title).to eq("Ubicloud - Forbidden")

        subject_tag = SubjectTag.create(project_id: project.id, name: "bar-group1")
        AccessControlEntry.create(project_id: project.id, subject_id: subject_tag.id)
        page.refresh
        expect(page.title).to eq("Ubicloud - Forbidden")

        subject_tag.update(name: "foo-group1")
        page.refresh
        expect(page.title).to eq("Ubicloud - Default - Audit Log")

        subject_tag.update(name: "foo-group2")
        page.refresh
        expect(page.title).to eq("Ubicloud - Default - Audit Log")

        subject_tag.update(name: "foo-group3")
        page.refresh
        expect(page.title).to eq("Ubicloud - Forbidden")

        subject_tag2 = SubjectTag.create(project_id: project.id, name: "bar-group1")
        subject_tag.add_member(subject_tag2.id)
        page.refresh
        expect(page.title).to eq("Ubicloud - Forbidden")

        subject_tag2.update(name: "foo-group1")
        page.refresh
        expect(page.title).to eq("Ubicloud - Default - Audit Log")

        subject_tag2.update(name: "foo-group2")
        page.refresh
        expect(page.title).to eq("Ubicloud - Default - Audit Log")
        expect(audit_log_hash).to eq({
          "login" => ip_hash("via" => "TestOIDC"),
          "logout" => ip_hash,
        })
      end

      it "can connect to existing account" do
        mock_provider(:github, "uSer@example.com")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Connect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("You have successfully connected your account with GitHub.")
        expect(audit_log_hash).to eq({"connect_provider" => ip_hash("provider" => "GitHub")})
      end

      it "can disconnect from existing account" do
        account.add_identity(provider: "google", uid: "123456790")
        account.add_identity(provider: "github", uid: "123456790")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Disconnect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("Your account has been disconnected from GitHub")
        expect(audit_log_hash).to eq({"disconnect_provider" => ip_hash("provider" => "GitHub")})
      end

      it "can delete password if another login method is available" do
        account.add_identity(provider: "google", uid: "123456790")

        visit "/account/login-method"
        within "#login-method-password" do
          click_button "Delete"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("Your password has been deleted")
        expect(audit_log_hash).to eq({"remove_password" => ip_hash})
      end

      it "can not disconnect the last login method if has no password" do
        DB[:account_password_hashes].where(id: account.id).delete
        account.add_identity(provider: "github", uid: "123456790")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Disconnect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("You must have at least one login method")
        expect(audit_log_hash).to eq({"disconnect_provider_failure" => ip_hash("reason" => "only remaining authentication method")})
      end

      it "can not remove password if the account has no remaining social login" do
        identity = account.add_identity(provider: "github", uid: "123456790")

        visit "/account/login-method"
        identity.destroy
        within "#login-method-password" do
          click_button "Delete"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("You must have at least one login method")
        expect(audit_log_hash).to eq({"remove_password_failure" => ip_hash("reason" => "only remaining authentication method")})
      end

      it "can not disconnect if it's already disconnected" do
        account.add_identity(provider: "google", uid: "123456790")
        account.add_identity(provider: "github", uid: "123456790")

        visit "/account/login-method"
        account.identities_dataset.first(provider: "github").update(uid: "0987654321")
        within "#login-method-github" do
          click_button "Disconnect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("Your account already has been disconnected from GitHub")
        expect(audit_log_hash).to eq({})
      end

      it "can not connect an account with different email" do
        mock_provider(:github, "user2@example.com")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Connect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("Your account's email address is different from the email address associated with the GitHub account.")
        expect(audit_log_hash).to eq({"connect_provider_failure" => ip_hash("reason" => "different email", "provider" => "GitHub")})
      end

      it "can not connect a social account with multiple accounts" do
        create_account("user2@example.com")
        mock_provider(:github, "user2@example.com")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Connect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("Your account's email address is different from the email address associated with the GitHub account.")
        expect(audit_log_hash).to eq({"connect_provider_failure" => ip_hash("reason" => "different email", "provider" => "GitHub")})
      end

      it "disallows changing password for an account in a locked domain" do
        oidc_provider.add_locked_domain(domain: "Example.com")

        visit "/account/change-password"
        fill_in "New Password", with: "#{TEST_USER_PASSWORD}_new"
        fill_in "New Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"
        click_button "Change Password"

        expect(Mail::TestMailer.deliveries.length).to eq 0
        expect(page).to have_flash_error("Changing passwords is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(audit_log_hash).to eq({"change_password_failure" => ip_hash("reason" => "locked domain")})
      end

      it "disallows requesting a login change for an account in a locked domain" do
        oidc_provider.add_locked_domain(domain: "Example.com")

        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(Mail::TestMailer.deliveries.length).to eq 0
        expect(page).to have_flash_error("Changing email addresses is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(audit_log_hash).to eq({"change_login_failure" => ip_hash("reason" => "locked domain")})
      end

      it "disallows changing login for an account in a locked domain" do
        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(page).to have_flash_notice("An email has been sent to you with a link to verify your login change")
        expect(Mail::TestMailer.deliveries.length).to eq 1
        verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

        oidc_provider.add_locked_domain(domain: "Example.com")

        visit verify_link
        click_button "Click to Verify New Email"

        expect(page).to have_flash_error("Changing email addresses is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(audit_log_hash).to eq({
          "change_login" => ip_hash,
          "verify_login_change_email" => ip_hash,
          "verify_login_change_failure" => ip_hash("reason" => "locked domain"),
        })
      end

      it "disallows requesting a login change for an account to a locked domain" do
        oidc_provider.add_locked_domain(domain: "other-example.com")

        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(Mail::TestMailer.deliveries.length).to eq 0
        expect(page).to have_flash_error("Changing email addresses is not supported for the other-example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(audit_log_hash).to eq({"change_login_failure" => ip_hash("reason" => "locked domain")})
      end

      it "disallows changing login for an account to a locked domain" do
        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(page).to have_flash_notice("An email has been sent to you with a link to verify your login change")
        expect(Mail::TestMailer.deliveries.length).to eq 1
        verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

        oidc_provider.add_locked_domain(domain: "other-example.com")

        visit verify_link
        click_button "Click to Verify New Email"

        expect(page).to have_flash_error("Changing email addresses is not supported for the other-example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
        expect(audit_log_hash).to eq({
          "change_login" => ip_hash,
          "verify_login_change_email" => ip_hash,
          "verify_login_change_failure" => ip_hash("reason" => "locked domain"),
        })
      end

      it "hides login methods, change password, and change emails options on My Account page" do
        oidc_provider.add_locked_domain(domain: "Example.com")
        visit "/account"
        expect(page).to have_no_content("Login Methods")
        expect(page).to have_no_content("Change Password")
        expect(page).to have_no_content("Change Email")
        expect(audit_log_hash).to eq({})
      end
    end
  end

  it "can not access without login" do
    visit "/account"

    expect(page.title).to eq("Ubicloud - Login")
    expect(audit_log_hash).to eq({})
  end
end
