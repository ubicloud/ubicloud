# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Sshable do
  # Avoid using excessive entropy by using one generated key for all
  # tests.
  key = SshKey.generate.keypair.freeze

  subject(:sa) {
    described_class.new(host: "test.localhost", raw_private_key_1: key)
  }

  it "can encrypt and decrypt a field" do
    sa.save_changes

    expect(sa.values[:raw_private_key_1] =~ /\AA[AgQ]..A/).not_to be_nil
    expect(sa.raw_private_key_1).to eq(key)
  end

  describe "caching" do
    # The cache is thread local, so re-set the thread state by boxing
    # each test in a new thread.
    around do |ex|
      Thread.new {
        ex.run
      }.join
    end

    it "can cache SSH connections" do
      expect(Net::SSH).to receive(:start) do
        instance_double(Net::SSH::Connection::Session, close: nil)
      end

      expect(Thread.current[:clover_ssh_cache]).to be_nil
      first_time = sa.connect
      expect(Thread.current[:clover_ssh_cache].size).to eq(1)
      second_time = sa.connect
      expect(first_time).to equal(second_time)

      expect(described_class.reset_cache).to eq []
      expect(Thread.current[:clover_ssh_cache]).to be_empty
    end

    it "does not crash if a cache has never been made" do
      expect {
        sa.invalidate_cache_entry
      }.not_to raise_error
    end

    it "can invalidate a single cache entry" do
      sess = instance_double(Net::SSH::Connection::Session, close: nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect
      expect {
        sa.invalidate_cache_entry
      }.to change { Thread.current[:clover_ssh_cache] }.from({"test.localhost" => sess}).to({})
    end

    it "can reset caches when has cached connection" do
      sess = instance_double(Net::SSH::Connection::Session, close: nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect
      expect {
        described_class.reset_cache
      }.to change { Thread.current[:clover_ssh_cache] }.from({"test.localhost" => sess}).to({})
    end

    it "can reset caches when has no cached connection" do
      expect(described_class.reset_cache).to eq([])
    end

    it "can reset caches even if session fails while closing" do
      sess = instance_double(Net::SSH::Connection::Session)
      expect(sess).to receive(:close).and_raise Sshable::SshError.new("bogus", nil, nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect

      expect(described_class.reset_cache.first).to be_a Sshable::SshError
      expect(Thread.current[:clover_ssh_cache]).to eq({})
    end
  end

  describe "#cmd" do
    let(:session) { instance_double(Net::SSH::Connection::Session) }

    before do
      expect(sa).to receive(:connect).and_return(session)
    end

    it "can run a command" do
      expect(session).to receive(:open_channel) do |&blk|
        chan = instance_spy(Net::SSH::Connection::Channel)
        expect(chan).to receive(:exec).with("echo hello") do |&blk|
          chan2 = instance_spy(Net::SSH::Connection::Channel)

          expect(chan2).to receive(:on_request).with("exit-status") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(0)
            blk.call(nil, buf)
          end

          expect(chan2).to receive(:on_data).and_yield(instance_double(Net::SSH::Connection::Channel), "hello")
          blk.call(chan2, true)
        end
        blk.call(chan, true)
        chan
      end

      expect(sa.cmd("echo hello")).to eq("hello")
    end

    it "raises an error with a non-zero exit status" do
      expect(session).to receive(:open_channel) do |&blk|
        chan = instance_spy(Net::SSH::Connection::Channel)
        expect(chan).to receive(:exec).with("exit 1") do |&blk|
          chan2 = instance_spy(Net::SSH::Connection::Channel)
          expect(chan2).to receive(:on_request).with("exit-status") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(1)
            blk.call(nil, buf)
          end

          expect(chan2).to receive(:on_request).with("exit-signal") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(127)
            blk.call(nil, buf)
          end

          expect(chan2).to receive(:on_extended_data) do |&blk|
            expect($stderr).to receive(:write).with("hello")
            blk.call(nil, "hello")
          end

          blk.call(chan2, true)
        end
        blk.call(chan, true)
        chan
      end

      expect { sa.cmd("exit 1") }.to raise_error Sshable::SshError, ""
    end

    it "invalidates the cache if the session raises an error" do
      err = IOError.new("the party is over")
      expect(session).to receive(:open_channel).and_raise err
      expect(sa).to receive(:invalidate_cache_entry)
      expect { sa.cmd("irrelevant") }.to raise_error err
    end
  end
end
