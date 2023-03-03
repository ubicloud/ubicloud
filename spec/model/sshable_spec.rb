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

  describe "#cmd" do
    let(:session) { instance_double(Net::SSH::Connection::Session) }

    before do
      expect(sa).to receive(:connect).and_return(session)
    end

    it "can run a command" do
      expect(session).to receive(:exec!).with("echo hello").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("hello", 0)
      )
      expect(sa.cmd("echo hello")).to eq("hello")
    end

    it "raises an error with a non-zeo exit status" do
      expect(session).to receive(:exec!).with("exit 1").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("", 1)
      )
      expect { sa.cmd("exit 1") }.to raise_error Sshable::SshError, ""
    end
  end
end
