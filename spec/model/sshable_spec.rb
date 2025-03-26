# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Sshable do
  # Avoid using excessive entropy by using one generated key for all
  # tests.
  key = SshKey.generate.keypair.freeze

  subject(:sa) {
    described_class.new(
      id: described_class.generate_uuid,
      host: "test.localhost",
      unix_user: "testuser",
      raw_private_key_1: key
    )
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
      }.to change { Thread.current[:clover_ssh_cache] }.from({["test.localhost", "testuser"] => sess}).to({})
    end

    it "can reset caches when has cached connection" do
      sess = instance_double(Net::SSH::Connection::Session, close: nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect
      expect {
        described_class.reset_cache
      }.to change { Thread.current[:clover_ssh_cache] }.from({["test.localhost", "testuser"] => sess}).to({})
    end

    it "can reset caches when has no cached connection" do
      expect(described_class.reset_cache).to eq([])
    end

    it "can reset caches even if session fails while closing" do
      sess = instance_double(Net::SSH::Connection::Session)
      expect(sess).to receive(:close).and_raise Sshable::SshError.new("bogus", "", "", nil, nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect

      expect(described_class.reset_cache.first).to be_a Sshable::SshError
      expect(Thread.current[:clover_ssh_cache]).to eq({})
    end
  end

  describe "#cmd" do
    let(:session) { instance_double(Net::SSH::Connection::Session) }

    before do
      expect(sa).to receive(:connect).and_return(session).at_least(:once)
    end

    def simulate(cmd:, exit_status:, exit_signal:, stdout:, stderr:)
      allow(session).to receive(:loop).and_yield
      expect(session).to receive(:open_channel) do |&blk|
        chan = instance_spy(Net::SSH::Connection::Channel)
        allow(chan).to receive(:connection).and_return(session)
        expect(chan).to receive(:exec).with(cmd) do |&blk|
          chan2 = instance_spy(Net::SSH::Connection::Channel)
          expect(chan2).to receive(:on_request).with("exit-status") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(exit_status)
            blk.call(nil, buf)
          end

          expect(chan2).to receive(:on_request).with("exit-signal") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(exit_signal)
            blk.call(nil, buf)
          end
          expect(chan2).to receive(:on_data).and_yield(instance_double(Net::SSH::Connection::Channel), stdout)
          expect(chan2).to receive(:on_extended_data).and_yield(nil, 1, stderr)
          allow(chan2).to receive(:connection).and_return(session)

          blk.call(chan2, true)
        end
        blk.call(chan, true)
        chan
      end
    end

    it "can run a command" do
      [false, true].each do |repl_value|
        [false, true].each do |log_value|
          allow(described_class).to receive(:repl?).and_return(repl_value)
          if repl_value
            # Note that in the REPL, stdout and stderr get multiplexed
            # into stderr in real time, packet by packet.
            expect($stderr).to receive(:write).with("hello")
            expect($stderr).to receive(:write).with("world")
          end

          if log_value
            sa.instance_variable_set(:@connect_duration, 1.1)
            expect(Clog).to receive(:emit).with("ssh cmd execution") do |&blk|
              dat = blk.call
              if repl_value
                expect(dat[:ssh].slice(:stdout, :stderr)).to be_empty
              else
                expect(dat[:ssh].slice(:stdout, :stderr)).to eq({stdout: "hello", stderr: "world"})
              end
            end
          end
          simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
          expect(sa.cmd("echo hello", log: log_value, timeout: nil)).to eq("hello")
        end
      end
    end

    it "raises an SshError with a non-zero exit status" do
      simulate(cmd: "exit 1", exit_status: 1, exit_signal: 127, stderr: "", stdout: "")
      expect { sa.cmd("exit 1", timeout: nil) }.to raise_error Sshable::SshError, "command exited with an error: exit 1"
    end

    it "raises an SshError with a nil exit status" do
      simulate(cmd: "exit 1", exit_status: nil, exit_signal: nil, stderr: "", stdout: "")
      expect { sa.cmd("exit 1", timeout: nil) }.to raise_error Sshable::SshTimeout, "command timed out: exit 1"
    end

    it "supports custom timeout" do
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false, timeout: 2)).to eq("hello")
    end

    it "suports default timeout" do
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false)).to eq("hello")
    end

    it "supports default timeout based on thread apoptosis_at variable if no explicit timeout is given if variable is available" do
      Thread.current[:apoptosis_at] = Time.now + 60
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false)).to eq("hello")
    ensure
      Thread.current[:apoptosis_at] = nil
    end

    it "invalidates the cache if the session raises an error" do
      err = IOError.new("the party is over")
      expect(session).to receive(:open_channel).and_raise err
      expect(sa).to receive(:invalidate_cache_entry)
      expect { sa.cmd("irrelevant") }.to raise_error err
    end
  end
end
