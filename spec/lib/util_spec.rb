# frozen_string_literal: true

require "rspec"
require_relative "../../lib/util"

RSpec.describe Util do
  describe "#rootish_ssh" do
    it "can execute a command" do
      expected_options = Sshable::COMMON_SSH_ARGS.merge(key_data: ["key1", "key2"])
      expect(Net::SSH).to receive(:start).with("hostname", "user", expected_options) do |&blk|
        sess = instance_double(Net::SSH::Connection::Session)
        expect(sess).to receive(:exec!).with("test command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it worked", 0)
        )
        blk.call sess
      end

      described_class.rootish_ssh("hostname", "user", ["key1", "key2"], "test command")
    end

    it "fails if a command fails" do
      expect(Net::SSH).to receive(:start) do |&blk|
        sess = instance_double(Net::SSH::Connection::Session)
        expect(sess).to receive(:exec!).with("failing command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it didn't work", 1)
        )
        blk.call sess
      end

      expect { described_class.rootish_ssh("hostname", "user", [], "failing command") }.to raise_error RuntimeError, "Ssh command failed: it didn't work"
    end
  end
end
