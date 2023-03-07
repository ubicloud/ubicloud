# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmHost do
  it "requires an Sshable too" do
    expect {
      sa = Sshable.create(host: "test.localhost", private_key: "test not a real private key")
      described_class.create { _1.id = sa.id }
    }.not_to raise_error
  end
end
