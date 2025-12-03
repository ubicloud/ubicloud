# frozen_string_literal: true

require "rspec"
require_relative "../../lib/util"

RSpec.describe Util do
  describe "#rootish_ssh" do
    it "can execute a command" do
      expected_options = Sshable::COMMON_SSH_ARGS.merge(key_data: ["key1", "key2"])
      expect(Net::SSH).to receive(:start).with("hostname", "user", expected_options) do |&blk|
        sess = Net::SSH::Connection::Session.allocate
        expect(sess).to receive(:_exec!).with("test command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it worked", 0)
        )
        blk.call sess
      end

      described_class.rootish_ssh("hostname", "user", ["key1", "key2"], "test command")
    end

    it "fails if a command fails" do
      expect(Net::SSH).to receive(:start) do |&blk|
        sess = Net::SSH::Connection::Session.allocate
        expect(sess).to receive(:_exec!).with("failing command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it didn't work", 1)
        )
        blk.call sess
      end

      expect { described_class.rootish_ssh("hostname", "user", [], "failing command") }.to raise_error RuntimeError, "Ssh command failed: it didn't work"
    end
  end

  describe "#parse_key" do
    it "can parse an elliptic key" do
      expect(described_class.parse_key(Clec::Cert::EC_KEY_PEM)).to be_instance_of OpenSSL::PKey::EC
    end

    it "can parse an RSA key" do
      expect(described_class.parse_key(Clec::Cert::RSA_KEY_PEM)).to be_instance_of OpenSSL::PKey::RSA
    end

    it "rejects unformatted information" do
      expect { described_class.parse_key("") }.to raise_error OpenSSL::PKey::RSAError
    end
  end
end
