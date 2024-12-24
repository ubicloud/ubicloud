# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Account do
  let(:account) { Account.create(email: "user@example.com") }

  it "can serialize without project_id" do
    data = described_class.serialize(account)
    expect(data[:policies]).to be_nil
  end
end
