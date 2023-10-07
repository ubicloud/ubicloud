# frozen_string_literal: true

# A bit of a hack, to re-use a different spec_helper, but otherwise
# these tests will crash DatabaseCleaner.
require_relative "../model/spec_helper"

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  describe "#scan" do
    it "exits if there's not enough database connections" do
      expect(Config).to receive(:db_pool).and_return(0).at_least(:once)
      expect(Clog).to receive(:emit).with("Not enough database connections.").and_call_original
      di.scan
    end
  end

  describe "#wait_cohort" do
    it "operates when no threads are running" do
      expect(di.wait_cohort).to be_zero
    end

    it "separates completed threads" do
      complete_r, complete_w = IO.pipe
      complete_w.close
      incomplete_r, incomplete_w = IO.pipe

      di.notifiers.concat([complete_r, incomplete_r])
      expect(di.wait_cohort).to eq 1

      expect(di.notifiers).to eq([incomplete_r])
    ensure
      [complete_r, complete_w, incomplete_r, incomplete_w].each(&:close)
    end
  end

  describe "#start_cohort" do
    after do
      expect(Thread.list.count).to eq(1)
    end

    it "can create threads" do
      # Isolate some thread local variables used for communication
      # within.
      Thread.new do
        th = Thread.current
        r, w = IO.pipe

        # Set a temporally-unique name that allows the Test strand to
        # find this thread and read its variables.
        th.name = "clover_test"

        # Pass part of a pipe: the test will synchronize by blocking
        # on it having been closed.
        th[:clover_test_in] = w

        # Ensure the test can be found by "#scan" and runs in a
        # thread.
        Strand.create_with_id(prog: "Test", label: "synchronized")
        di.start_cohort
        expect(di.notifiers.count).to be 1

        # Blocks until :clover_test_out has been set.
        r.read
        r.close

        # Wait until thread has changed "alive?" status to "false".
        th.thread_variable_get(:clover_test_out).join

        # Expect a dead thread to get reaped by wait_cohort.
        di.wait_cohort
        expect(di.notifiers).to be_empty
      ensure
        # Multiple transactions are required for this test across
        # threads, so we need to clean up differently than
        # DatabaseCleaner would.
        Strand.truncate(cascade: true)
      end.join
    end

    it "can trigger thread dumps and exit if the Prog takes too long" do
      expect(ThreadPrinter).to receive(:run)
      expect(Kernel).to receive(:exit!)

      Thread.new do
        th = Thread.current
        r, w = IO.pipe
        th.name = "clover_test"
        th[:clover_test_in] = r

        di.instance_variable_set(:@apoptosis_timeout, 0)
        Strand.create_with_id(prog: "Test", label: "wait_exit")
        di.start_cohort
        w.close
        di.notifiers.each(&:read)
      ensure
        Strand.truncate(cascade: true)
      end.join
    end
  end
end
