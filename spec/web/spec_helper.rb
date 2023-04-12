# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?("test")

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

  config.before(:suite) do
    create_user_if_not_exist("user@example.com", "0123456789")
    create_user_if_not_exist("user2@example.com", "0123456789")
  end
end

def create_user_if_not_exist(email, password)
  # Create a default user to use in all test if not exits
  # Database cleaner can't trunca accounts tables because of
  # account of `ph` user separation.

  user = Account[email: email] || begin
    hash = Argon2::Password.new({
      t_cost: 1,
      m_cost: 3,
      secret: Config.clover_session_secret
    }).create(password)

    account = Account.create(email: email, status_id: 2)
    DB[:account_password_hashes].insert(id: account.id, password_hash: hash)

    account
  end
  user.create_tag_space_with_default_policy("#{user.username}_tag_space")
  user
end

def login(email = "user@example.com", password = "0123456789")
  visit "/login"
  fill_in "Email address", with: email
  fill_in "Password", with: password
  click_button "Sign in"

  expect(page.title).to eq("Ubicloud - Dashboard")
end
