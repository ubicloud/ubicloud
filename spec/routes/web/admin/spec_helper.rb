# frozen_string_literal: true

require_relative "../spec_helper"

require "webauthn/fake_client"

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{\A\./spec/routes/web/admin/}) do |metadata|
    metadata[:clover_admin] = true
  end

  config.before do |example|
    Capybara.default_host = "http://admin.ubicloud.com" if example.metadata[:clover_admin]
  end

  config.include(Module.new do
    def admin_webauthn_client
      @admin_webauthn_client ||= WebAuthn::FakeClient.new("http://admin.ubicloud.com")
    end

    def admin_account_setup_and_login(password: TEST_USER_PASSWORD)
      CloverAdmin.create_admin_account("admin", password)
      visit "/"
      admin_login(password:)
      admin_webauthn_auth_setup(password:)
    end

    def admin_login(password: TEST_USER_PASSWORD)
      fill_in "Login", with: "admin"
      fill_in "Password", with: password
      click_button "Login"
    end

    def admin_webauthn_auth_setup(password: TEST_USER_PASSWORD)
      challenge = JSON.parse(page.find_by_id("webauthn-setup-form")["data-credential-options"])["challenge"]
      fill_in "Password", with: password
      fill_in "webauthn_setup", with: admin_webauthn_client.create(challenge:).to_json
      click_button "Setup WebAuthn Authentication"
      expect(page).to have_flash_notice("WebAuthn authentication is now setup")
    end

    def admin_webauthn_auth
      challenge = JSON.parse(page.find_by_id("webauthn-auth-form")["data-credential-options"])["challenge"]
      fill_in "webauthn_auth", with: admin_webauthn_client.get(challenge: challenge).to_json
      click_button "Authenticate Using WebAuthn"
    end
  end)
end
