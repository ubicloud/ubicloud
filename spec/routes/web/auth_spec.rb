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
  end

  it "can create new account, verify it, and visit project which invited" do
    p = Project.create_with_id(name: "Invited-project")
    p.add_invitation(email: TEST_USER_EMAIL, inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

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

    visit "#{p.path}/dashboard"
    expect(page.title).to eq("Ubicloud - #{p.name} Dashboard")
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
  end

  it "can create new account, verify it, and visit project which invited with default policy" do
    p = Project.create_with_id(name: "Invited-project")
    subject_id = SubjectTag.create_with_id(project_id: p.id, name: "Admin").id
    AccessControlEntry.create_with_id(project_id: p.id, subject_id:, action_id: ActionType::NAME_MAP["Project:view"])
    p.add_invitation(email: TEST_USER_EMAIL, policy: "Admin", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

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

    click_button "Verify Account"
    expect(page.title).to eq("Ubicloud - Default Dashboard")

    visit p.path
    expect(page.title).to eq("Ubicloud - #{p.name}")
  end

  it "can remember login" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    expect(DB[:account_remember_keys].first(id: account.id)).not_to be_nil
  end

  it "has correct current user when logged in via remember token" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    page.refresh
    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
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
  end

  it "can login to an account without projects" do
    create_account(with_project: false)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Projects")
  end

  it "can not login if the account is suspended" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"
    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")

    account.suspend

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error(/Your account has been suspended.*/)
  end

  it "can not login if the account is suspended via remember token" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    account.suspend
    page.refresh
    expect(page.title).to eq("Ubicloud - Login")
  end

  it "redirects to otp page if the otp is only 2FA method" do
    create_account(enable_otp: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
  end

  it "redirects to webauthn page if the webauthn is only 2FA method" do
    create_account(enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - Security Keys")
  end

  it "shows 2FA method list if there are multiple 2FA methods" do
    create_account(enable_otp: true, enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    click_button "Sign in"
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Two-factor Authentication")
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
        verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

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
    end

    [true, false].each do |clear_last_password_entry|
      it "can change password when password entry is #{"not " unless clear_last_password_entry}required" do
        visit "/clear-last-password-entry" if clear_last_password_entry
        visit "/account/change-password"

        fill_in "Current Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        fill_in "New Password", with: "#{TEST_USER_PASSWORD}_new"
        fill_in "New Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

        click_button "Change Password"

        expect(page.title).to eq("Ubicloud - Change Password")

        click_button "Log out"

        expect(page.title).to eq("Ubicloud - Login")

        fill_in "Email Address", with: TEST_USER_EMAIL
        click_button "Sign in"
        fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"

        click_button "Sign in"
      end

      it "can close account when password entry is #{"not " unless clear_last_password_entry}required" do
        visit "/clear-last-password-entry" if clear_last_password_entry
        account = Account[email: TEST_USER_EMAIL]
        UsageAlert.create_with_id(project_id: account.projects.first.id, user_id: account.id, name: "test", limit: 100)

        visit "/account/close-account"

        fill_in "Password", with: TEST_USER_PASSWORD if clear_last_password_entry
        click_button "Close Account"

        expect(page.title).to eq("Ubicloud - Login")
        expect(page).to have_flash_notice("Your account has been closed")

        expect(Account[email: TEST_USER_EMAIL]).to be_nil
        expect(DB[:access_tag].where(hyper_tag_id: account.id).count).to eq 0
      end
    end

    it "can not close account if the project has some resources" do
      vm = create_vm
      project = Account[email: TEST_USER_EMAIL].projects.first
      vm.update(project_id: project.id)

      visit "/account/close-account"

      click_button "Close Account"

      expect(page.title).to eq("Ubicloud - Close Account")
      expect(page).to have_flash_error("'#{project.name}' project has some resources. Delete all related resources first.")
    end
  end

  describe "social login" do
    def mock_provider(provider, email = TEST_USER_EMAIL, name: "John Doe", mock_config: true)
      expect(Config).to receive("omniauth_#{provider}_id").and_return("12345").at_least(:once) if mock_config
      OmniAuth.config.add_mock(provider, {
        provider: provider,
        uid: "123456790",
        info: {
          name:,
          email: email
        }
      })
    end

    let(:oidc_provider) do
      OidcProvider.create(
        display_name: "TestOIDC",
        client_id: "123",
        client_secret: "456",
        url: "http://example.com",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw"
      )
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
        provider.add_locked_domain(domain: "example.com") if locked_domain
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
      end
    end

    it "cannot login to an account via password when domain is locked" do
      oidc_provider.add_locked_domain(domain: "example.com")
      account = create_account
      visit "/login"
      fill_in "Email Address", with: account.email
      click_button "Sign in"
      fill_in "Password", with: TEST_USER_PASSWORD
      click_button "Sign in"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Login via username and password is not supported for the example.com domain. You must authenticate using TestOIDC.")
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

      oidc_provider.add_locked_domain(domain: "example.com")
      visit verify_link
      click_button "Verify Account"
      expect(page).to have_flash_error("Verifying accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
      expect(Account.all).to eq []
    end

    it "attempting to create an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "example.com")

      visit "/create-account"
      fill_in "Email Address", with: TEST_USER_EMAIL
      fill_in "Full Name", with: "John Doe"
      fill_in "Password", with: TEST_USER_PASSWORD
      fill_in "Password Confirmation", with: TEST_USER_PASSWORD
      click_button "Create Account"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Creating accounts with a password is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
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

      oidc_provider.add_locked_domain(domain: "example.com")
      visit reset_link
      fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"
      fill_in "Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Reset Password"

      expect(page).to have_flash_error("Resetting passwords is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
    end

    it "requesting a password reset for an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "example.com")

      create_account

      visit "/login"
      click_link "Forgot your password?"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Request Password Reset"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Resetting passwords is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
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

      oidc_provider.add_locked_domain(domain: "example.com")
      visit unlock_link
      click_button "Unlock Account"

      expect(page).to have_flash_error("Unlocking accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
    end

    it "requesting an account unlock for an account in a locked domain redirects to required OIDC login page" do
      oidc_provider.add_locked_domain(domain: "example.com")

      account = create_account
      DB[:account_lockouts].insert(id: account.id, key: SecureRandom.urlsafe_base64(32))

      visit "/login"
      fill_in "Email Address", with: TEST_USER_EMAIL
      click_button "Sign in"
      click_button "Request Account Unlock"

      expect(Mail::TestMailer.deliveries.length).to eq 0
      expect(page).to have_flash_error("Unlocking accounts is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(page).to have_current_path "/auth/#{oidc_provider.ubid}"
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
        jwks_uri: "https://host/jw"
      )

      visit "/auth/#{provider.ubid}"
      OmniAuth.config.add_mock(provider.ubid.to_sym, provider: provider.ubid, uid: "789",
        info: {email: "user@example.com"})
      click_button "Login"

      account = Account.first
      expect(account.email).to eq "user@example.com"
      expect(AccountIdentity.select_hash(:account_id, :provider)).to eq(account.id => provider.ubid)

      click_button "Log out"
      oidc_provider.add_locked_domain(domain: "example.com")

      visit "/auth/#{provider.ubid}"
      click_button "Login"
      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Login via TestOIDC2 is not supported for the example.com domain. You must authenticate using TestOIDC.")
    end

    it "cannot create account via an omniauth provider when domain is locked to a different provider" do
      oidc_provider.add_locked_domain(domain: "example.com")
      provider = OidcProvider.create(
        display_name: "TestOIDC2",
        client_id: "123",
        client_secret: "456",
        url: "http://example.com",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw"
      )

      visit "/auth/#{provider.ubid}"
      OmniAuth.config.add_mock(provider.ubid.to_sym, provider: provider.ubid, uid: "789",
        info: {email: "user@example.com"})
      click_button "Login"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error("Creating an account via authentication through TestOIDC2 is not supported for the example.com domain. You must authenticate using TestOIDC.")
      expect(Account.all).to eq []
      expect(AccountIdentity.all).to eq []
    end

    it "shows error message if attempting to create an account where social login has no email" do
      mock_provider(:github, nil)

      visit "/login"
      click_button "GitHub"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error(/Social login is only allowed if social login provider provides email/)
    end

    it "can create new account even if social account doesn't have a name" do
      mock_provider(:github, name: nil)

      visit "/login"
      click_button "GitHub"

      expect(Account[email: TEST_USER_EMAIL].name).to eq "User"
    end

    it "can create new account" do
      mock_provider(:github)

      visit "/login"
      click_button "GitHub"

      account = Account[email: TEST_USER_EMAIL]
      expect(account).not_to be_nil
      expect(account.identities_dataset.first(provider: "github", uid: "123456790")).not_to be_nil
      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
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
      expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    end

    it "can not login existing account before linking it" do
      mock_provider(:github)
      create_account

      visit "/login"
      click_button "GitHub"

      expect(page.status_code).to eq(200)
      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_flash_error(/There is already an account with this email address.*/)
    end

    describe "authenticated" do
      let(:account) { create_account }

      before do
        login(account.email)
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
      ensure
        OmniAuth.config.mock_auth[omniauth_key] = nil
      end

      [true, false].each do |locked_domain|
        it "can login via OIDC flow with already connected account using normal login page#{" when domain is locked" if locked_domain}" do
          omniauth_key = oidc_provider.ubid.to_sym
          oidc_provider.add_locked_domain(domain: "example.com") if locked_domain
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
        end

        it "can login via OIDC flow with already connected account using normal login page when account does not have password#{" when domain is locked" if locked_domain}" do
          omniauth_key = oidc_provider.ubid.to_sym
          oidc_provider.add_locked_domain(domain: "example.com") if locked_domain
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
        end
      end

      it "can connect to existing account" do
        mock_provider(:github, "uSer@example.com")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Connect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("You have successfully connected your account with GitHub.")
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
      end

      it "can delete password if another login method is available" do
        account.add_identity(provider: "google", uid: "123456790")

        visit "/account/login-method"
        within "#login-method-password" do
          click_button "Delete"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_notice("Your password has been deleted")
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
      end

      it "can not connect an account with different email" do
        mock_provider(:github, "user2@example.com")

        visit "/account/login-method"
        within "#login-method-github" do
          click_button "Connect"
        end

        expect(page.title).to eq("Ubicloud - Login Methods")
        expect(page).to have_flash_error("Your account's email address is different from the email address associated with the GitHub account.")
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
      end

      it "disallows changing password for an account in a locked domain" do
        oidc_provider.add_locked_domain(domain: "example.com")

        visit "/account/change-password"
        fill_in "New Password", with: "#{TEST_USER_PASSWORD}_new"
        fill_in "New Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"
        click_button "Change Password"

        expect(Mail::TestMailer.deliveries.length).to eq 0
        expect(page).to have_flash_error("Changing passwords is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
      end

      it "disallows requesting a login change for an account in a locked domain" do
        oidc_provider.add_locked_domain(domain: "example.com")

        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(Mail::TestMailer.deliveries.length).to eq 0
        expect(page).to have_flash_error("Changing email addresses is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
      end

      it "disallows changing login for an account in a locked domain" do
        visit "/account/change-login"
        fill_in "New Email Address", with: "user@other-example.com"
        click_button "Change Email"

        expect(page).to have_flash_notice("An email has been sent to you with a link to verify your login change")
        expect(Mail::TestMailer.deliveries.length).to eq 1
        verify_link = Mail::TestMailer.deliveries.first.html_part.body.match(/(\/verify-login-change.+?)"/)[1]

        oidc_provider.add_locked_domain(domain: "example.com")

        visit verify_link
        click_button "Click to Verify New Email"

        expect(page).to have_flash_error("Changing email addresses is not supported for the example.com domain.")
        expect(page.title).to eq("Ubicloud - Default Dashboard")
      end

      it "hides login methods, change password, and change emails options on My Account page" do
        oidc_provider.add_locked_domain(domain: "example.com")
        visit "/account"
        expect(page).to have_no_content("Login Methods")
        expect(page).to have_no_content("Change Password")
        expect(page).to have_no_content("Change Email")
      end
    end
  end
end
