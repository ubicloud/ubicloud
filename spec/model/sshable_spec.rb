# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Sshable do
  subject(:sa) {
    described_class.new(host: "test.localhost", private_key: "test not a real private key")
  }

  it "can encrypt and decrypt a field" do
    sa.save_changes

    expect(sa.values[:private_key] =~ /\AA[AgQ]..A/).not_to be_nil
    expect(sa.private_key).to eq("test not a real private key")
  end

  it "can cache SSH connections" do
    expect(Net::SSH).to receive(:start).and_return instance_double(Net::SSH::Connection::Session, close: nil)
    first_time = sa.connect
    second_time = sa.connect
    expect(first_time).to equal(second_time)

    expect(sa.clear_cache).to eq []
  end
end
