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
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

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

  it "can create new account, verify it, and visit project which invited" do
    p = Project.create_with_id(name: "Invited project").tap { _1.associate_with_project(_1) }
    p.add_invitation(email: TEST_USER_EMAIL, inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

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
    expect(page.title).to eq("Ubicloud - Default Dashboard")

    visit "#{p.path}/dashboard"
    expect(page.title).to eq("Ubicloud - #{p.name} Dashboard")
  end

  it "can create new account, verify it, and visit project which invited with default policy" do
    p = Project.create_with_id(name: "Invited project").tap { _1.associate_with_project(_1) }
    p.add_invitation(email: TEST_USER_EMAIL, policy: "admin", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf", expires_at: Time.now + 7 * 24 * 60 * 60)

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
    expect(page.title).to eq("Ubicloud - Default Dashboard")

    visit p.path
    expect(page.title).to eq("Ubicloud - #{p.name}")
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

  it "has correct current user when logged in via remember token" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    # page.refresh does not work, sends deleted _Clover.session cookie
    visit page.current_path
    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
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

    fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"
    fill_in "Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

    click_button "Reset Password"

    expect(page.title).to eq("Ubicloud - Login")

    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"

    click_button "Sign in"
  end

  it "can login to an account without projects" do
    create_account(with_project: false)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Projects")
  end

  it "can not login if the account is suspended" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"
    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")

    account.suspend

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_content("Your account has been suspended")
  end

  it "can not login if the account is suspended via remember token" do
    account = create_account

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    check "Remember me"
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - #{account.projects.first.name} Dashboard")
    page.driver.browser.rack_mock_session.cookie_jar.delete("_Clover.session")
    account.suspend
    # page.refresh does not work, sends deleted _Clover.session cookie
    visit page.current_path
    expect(page.title).to eq("Ubicloud - Login")
  end

  it "redirects to otp page if the otp is only 2FA method" do
    create_account(enable_otp: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - One-Time Password")
  end

  it "redirects to webauthn page if the webauthn is only 2FA method" do
    create_account(enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - 2FA - Security Keys")
  end

  it "shows 2FA method list if there are multiple 2FA methods" do
    create_account(enable_otp: true, enable_webauthn: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    click_button "Sign in"

    expect(page.title).to eq("Ubicloud - Two-factor Authentication")
  end

  it "shows enter recovery codes page" do
    create_account(enable_otp: true)

    visit "/login"
    fill_in "Email Address", with: TEST_USER_EMAIL
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

      click_button "Click to Verify New Email"

      expect(page.title).to eq("Ubicloud - Default Dashboard")

      click_button "Log out"

      expect(page.title).to eq("Ubicloud - Login")

      fill_in "Email Address", with: new_email
      fill_in "Password", with: TEST_USER_PASSWORD

      click_button "Sign in"
    end

    it "can change password" do
      visit "/account/change-password"

      fill_in "New Password", with: "#{TEST_USER_PASSWORD}_new"
      fill_in "New Password Confirmation", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Change Password"

      expect(page.title).to eq("Ubicloud - Change Password")

      click_button "Log out"

      expect(page.title).to eq("Ubicloud - Login")

      fill_in "Email Address", with: TEST_USER_EMAIL
      fill_in "Password", with: "#{TEST_USER_PASSWORD}_new"

      click_button "Sign in"
    end

    it "can close account" do
      account = Account[email: TEST_USER_EMAIL]
      UsageAlert.create_with_id(project_id: account.projects.first.id, user_id: account.id, name: "test", limit: 100)

      visit "/account/close-account"

      click_button "Close Account"

      expect(page.title).to eq("Ubicloud - Login")
      expect(page).to have_content("Your account has been closed")

      expect(Account[email: TEST_USER_EMAIL]).to be_nil
      expect(AccessTag.where(name: "user/#{TEST_USER_EMAIL}").count).to eq 0
    end

    it "can not close account if the project has some resources" do
      vm = create_vm
      vm.associate_with_project(Account[email: TEST_USER_EMAIL].projects.first)

      visit "/account/close-account"

      click_button "Close Account"

      expect(page.title).to eq("Ubicloud - Close Account")
      expect(page).to have_content("project has some resources. Delete all related resources first")
    end
  end
end
