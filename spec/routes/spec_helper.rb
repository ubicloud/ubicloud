# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?("test")

TEST_USER_EMAIL = "user@example.com"
TEST_USER_PASSWORD = "Secret@Password123"
TEST_LOCATION = "hetzner-hel1"

def create_account(email = TEST_USER_EMAIL, password = TEST_USER_PASSWORD)
  hash = Argon2::Password.new({
    t_cost: 1,
    m_cost: 3,
    secret: Config.clover_session_secret
  }).create(password)

  account = Account.create(email: email, status_id: 2)
  DB[:account_password_hashes].insert(id: account.id, password_hash: hash)
  account.create_project_with_default_policy("#{account.username}-project")
  account
end
