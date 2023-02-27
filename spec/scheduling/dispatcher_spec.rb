# frozen_string_literal: true

# A bit of a hack, to re-use a different spec_helper, but otherwise
# these tests will crash DatabaseCleaner.
require_relative "../model/spec_helper"

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  describe "#wait_cohort" do
    it "operates when no threads are running" do
      expect { di.wait_cohort }.not_to raise_error
    end

    it "filters for live threads only" do
      di.threads << instance_double(Thread, alive?: true)
      want = di.threads.dup.freeze
      di.threads << instance_double(Thread, alive?: false)

      di.wait_cohort

      expect(di.threads).to eq(want)
    end
  end

  describe "#start_cohort" do
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
        s = Strand.create(schedule: Time.now, prog: "Test", label: "synchronized")
        di.start_cohort
        expect(di.threads.count).to be 1
        expect(di.threads[0].name).to eq(s.id)

        # Blocks until :clover_test_out has been set.
        r.read
        r.close

        # Wait until thread has changed "alive?" status to "false".
        th.thread_variable_get(:clover_test_out).join

        # Expect a dead thread to get reaped by wait_cohort.
        di.wait_cohort
        expect(di.threads).to be_empty
      ensure
        # Multiple transactions are required for this test across
        # threads, so we need to clean up differently than
        # DatabaseCleaner would.
        Strand.truncate(cascade: true)
      end.join
    end

    it "can trigger thread dumps and exit if the Prog takes too long" do
      Thread.new do
        th = Thread.current
        r, w = IO.pipe
        th.name = "clover_test"
        th[:clover_test_in] = r

        di.instance_variable_set(:@apoptosis_timeout, 0)
        di.instance_variable_set(:@dump_timeout, 0)
        Strand.create(schedule: Time.now, prog: "Test", label: "wait_exit")
        di.start_cohort
        expect(Ractor.receive).to eq :thread_dump
        w.close
      ensure
        Strand.truncate(cascade: true)
      end.join
    end
  end
end
