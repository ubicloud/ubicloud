# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?("test")

require "capybara"
require "capybara/rspec"
require "rack/test"
require "argon2"

Gem.suffix_pattern

Clover.plugin :error_handler do |e|
  raise e
end

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

  config.before(:suite) do
    # Create a default user to use in all test if not exits
    # Database cleaner can't trunca accounts tables because of
    # account of `ph` user separation.
    unless DB[:accounts].where(email: "user@example.com").first
      hash = Argon2::Password.new({
        t_cost: 1,
        m_cost: 3,
        secret: Config.clover_session_secret
      }).create("0123456789")

      account_id = DB[:accounts].insert(email: "user@example.com", status_id: 2)
      DB[:account_password_hashes].insert(id: account_id, password_hash: hash)
    end
  end
end

def login(email = "user@example.com", password = "0123456789")
  visit "/login"
  fill_in "Email address", with: email
  fill_in "Password", with: password
  click_button "Sign in"

  expect(page.title).to eq("Ubicloud - Dashboard")
end
