# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  it "handles CSRF token errors" do
    page.driver.post("/login")

    expect(page.title).to eq("Ubicloud - Invalid Security Token")
  end

  it "handles unexpected errors" do
    expect(Account).to receive(:[]).and_raise(RuntimeError)

    visit "/create-account"
    fill_in "Email Address", with: TEST_USER_EMAIL
    fill_in "Password", with: TEST_USER_PASSWORD
    fill_in "Password Confirmation", with: TEST_USER_PASSWORD

    expect { click_button "Create Account" }.to output(/RuntimeError.*/).to_stderr

    expect(page.title).to eq("Ubicloud - Unexcepted Error")
  end
end
