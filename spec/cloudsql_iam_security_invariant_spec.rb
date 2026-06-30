# frozen_string_literal: true

require_relative "spec_helper"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Rodauth password-hash isolation invariant" do
  it "app role cannot SELECT account_password_hashes" do
    expect(DB["SELECT has_table_privilege('clover', 'account_password_hashes', 'SELECT')"].get).to be(false)
  end

  it "app role is not a member of clover_password" do
    expect(DB["SELECT pg_has_role('clover', 'clover_password', 'MEMBER')"].get).to be(false)
  end
end
# rubocop:enable RSpec/DescribeClass
