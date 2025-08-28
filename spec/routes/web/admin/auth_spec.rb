# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  unless ENV["CLOVER_FREEZE"] == "1"
    it "does not allow calling create_admin_account inside Pry" do
      expect(Config).to receive(:production?).and_return(true)
      stub_const("CloverAdmin::Pry", true)
      expect { described_class.create_admin_account("foo") }.to raise_error(RuntimeError)
    end
  end

  it "shows invalid security token if CSRF token is not valid" do
    visit "/login"
    find(".rodauth input[name=_csrf]", visible: false).set("")
    click_button "Login"
    expect(page.title).to eq "Ubicloud Admin - Invalid Security Token"
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
    expect(page).to have_flash_notice("You have been multifactor authenticated")
    expect(page.title).to eq "Ubicloud Admin"
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
  end

  it "supports removing webauthn authenticator" do
    admin_account_setup_and_login
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
  end
end
