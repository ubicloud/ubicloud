# frozen_string_literal: true

require_relative "../spec_helper"

require "capybara"
require "capybara/rspec"
require "rack/test"
require "argon2"

Gem.suffix_pattern

Capybara.app = Clover.freeze.app
Capybara.exact = true

module RackTestPlus
  include Rack::Test::Methods

  def app
    Capybara.app
  end
end

RSpec.configure do |config|
  config.include RackTestPlus
  config.include Capybara::DSL
  config.after do
    Capybara.reset_sessions!
    Capybara.use_default_driver
  end
end

def login(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
  visit "/login"
  fill_in "Email Address", with: email
  fill_in "Password", with: password
  click_button "Sign in"

  expect(page.title).to end_with("Dashboard")
end
