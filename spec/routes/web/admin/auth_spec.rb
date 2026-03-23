# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  def ip_hash(into = {})
    into["ip"] = "127.0.0.1"
    into
  end

  def audit_log_hash
    DB[:admin_account_authentication_audit_log].select_hash(:message, :metadata)
  end

  def admin_account_setup_and_login
    super
    DB[:admin_account_authentication_audit_log].delete
  end

  def webauthn_token_prefix
    DB[:admin_webauthn_key].get(:webauthn_id)[0...8]
  end

  before do
    expect(self).to receive(:audit_log_hash).and_call_original
  end

  if Config.unfrozen_test?
    it "does not allow calling create_admin_account inside Pry" do
      expect(Config).to receive(:production?).and_return(true)
      stub_const("CloverAdmin::Pry", true)
      expect { described_class.create_admin_account("foo") }.to raise_error(RuntimeError)
      expect(audit_log_hash).to eq({})
    end
  end

  it "shows invalid security token if CSRF token is not valid" do
    visit "/login"
    find(".rodauth input[name=_csrf]", visible: false).set("")
    click_button "Login"
    expect(page.title).to eq "Ubicloud Admin - Invalid Security Token"
    expect(audit_log_hash).to eq({})
  end

  it "requires password and webauthn authentication both for setup and login" do
    account = create_account

    visit "/"
    expect(page.title).to eq "Ubicloud Admin - Login"

    fill_in "Login", with: account.email
    fill_in "Password", with: @password
    click_button "Login"
    expect(page).to have_flash_error("There was an error logging in")
    expect(page).to have_content("no matching login")
    expect(page.title).to eq "Ubicloud Admin - Login"

    password = @password = described_class.create_admin_account("admin")

    fill_in "Login", with: "admin"
    fill_in "Password", with: "bad"
    click_button "Login"
    expect(page).to have_flash_error("There was an error logging in")
    expect(page).to have_content("invalid password")
    expect(page.title).to eq "Ubicloud Admin - Login"

    fill_in "Login", with: "admin"
    fill_in "Password", with: password
    click_button "Login"
    expect(page).to have_flash_notice("You have been logged in")
    expect(page.title).to eq "Ubicloud Admin - Setup WebAuthn Authentication"

    admin_webauthn_auth_setup
    expect(page).to have_flash_notice("WebAuthn authentication is now setup")
    expect(page.title).to eq "Ubicloud Admin"

    click_button "Logout"
    expect(page).to have_flash_notice("You have been logged out")
    expect(page.title).to eq "Ubicloud Admin - Login"

    fill_in "Login", with: "admin"
    fill_in "Password", with: password
    click_button "Login"
    expect(page).to have_flash_notice("You have been logged in")
    expect(page.title).to eq "Ubicloud Admin - Authenticate Using WebAuthn"

    admin_webauthn_auth
    token = webauthn_token_prefix

    expect(page).to have_flash_notice("You have been multifactor authenticated")
    expect(page.title).to eq "Ubicloud Admin"
    expect(audit_log_hash).to eq({
      "create_account" => {},
      "login" => ip_hash,
      "login_failure" => ip_hash,
      "logout" => ip_hash,
      "two_factor_authentication" => ip_hash("token" => token),
      "webauthn_setup" => ip_hash("token" => token)
    })
  end

  it "requires account to still exist" do
    admin_account_setup_and_login
    expect(page.title).to eq "Ubicloud Admin"
    DB[:admin_webauthn_key].delete
    DB[:admin_webauthn_user_id].delete
    DB[:admin_password_hash].delete
    DB[:admin_account].delete
    page.refresh
    expect(page.title).to eq "Ubicloud Admin - Login"
    expect(audit_log_hash).to eq({})
  end

  it "supports changing password" do
    admin_account_setup_and_login
    click_link "Change Password"
    fill_in "Password", with: @password
    password = @password = TEST_USER_PASSWORD + "1"
    fill_in "New Password", with: password
    fill_in "Confirm Password", with: password
    click_button "Change Password"
    expect(page).to have_flash_notice("Your password has been changed")
    expect(page.title).to eq "Ubicloud Admin"

    click_button "Logout"
    expect(page).to have_flash_notice("You have been logged out")
    expect(page.title).to eq "Ubicloud Admin - Login"

    admin_login
    admin_webauthn_auth
    expect(page).to have_flash_notice("You have been multifactor authenticated")
    expect(page.title).to eq "Ubicloud Admin"
    expect(audit_log_hash).to eq({
      "change_password" => ip_hash,
      "logout" => ip_hash,
      "login" => ip_hash,
      "two_factor_authentication" => ip_hash("token" => webauthn_token_prefix)
    })
  end

  it "supports removing webauthn authenticator" do
    admin_account_setup_and_login
    old_token = webauthn_token_prefix

    click_link "Manage Multifactor Authentication"
    click_link "Remove WebAuthn Authenticator"
    fill_in "Password", with: @password
    choose "webauthn_remove"
    click_button "Remove WebAuthn Authenticator"

    expect(page).to have_flash_error("This account has not been setup for multifactor authentication")
    expect(DB[:admin_webauthn_key].all).to eq []
    expect(DB[:admin_webauthn_user_id].count).to eq 1

    admin_webauthn_auth_setup
    expect(page).to have_flash_notice("WebAuthn authentication is now setup")
    expect(page.title).to eq "Ubicloud Admin"
    expect(audit_log_hash).to eq({
      "webauthn_remove" => ip_hash("token" => old_token),
      "webauthn_setup" => ip_hash("token" => webauthn_token_prefix)
    })
  end

  it "supports admins closing their own accounts" do
    admin_account_setup_and_login
    click_link "Close Account"
    fill_in "Password", with: @password
    expect(Clog).to receive(:emit).with("Admin account closed", {admin_account_closed: {account_closed: "admin", closer: "admin"}}).and_call_original
    click_button "Close Account"
    expect(page).to have_flash_notice("Your account has been closed")
    expect(page.title).to eq "Ubicloud Admin - Login"
    expect(DB[:admin_account].count).to eq 0
    expect(audit_log_hash).to eq({"close_account" => ip_hash})
  end

  it "allows closing other admin accounts" do
    admin_account_setup_and_login
    DB[:admin_account].insert(login: "foo")
    click_link "View Admin List"
    expect(page.title).to eq "Ubicloud Admin - Admin List"
    expect(page.all("#admin-list li").map(&:text)).to eq ["admin", "foo"]
    select "foo"
    expect(Clog).to receive(:emit).with("Admin account closed", {admin_account_closed: {account_closed: "foo", closer: "admin"}}).and_call_original
    click_button "Close Admin Account"
    expect(page).to have_flash_notice "Admin account \"foo\" closed."
    expect(page.all("#admin-list li").map(&:text)).to eq ["admin"]

    DB[:admin_account].insert(login: "foo")
    page.refresh
    DB[:admin_account].where(login: "foo").delete
    select "foo"
    click_button "Close Admin Account"
    expect(page).to have_flash_error "Unable to close admin account for \"foo\"."
    expect(audit_log_hash).to eq({"close_account" => ip_hash({"closer" => "admin"})})
  end
end
