# frozen_string_literal: true

# A bit of a hack, to re-use a different spec_helper, but otherwise
# these tests will crash DatabaseCleaner.
require_relative "../model/spec_helper"

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  describe "#scan" do
    it "exits if there's not enough database connections" do
      expect(Config).to receive(:db_pool).and_return(0).at_least(:once)
      expect(di).to receive(:puts).with("Not enough database connections. Waiting active connections to finish their work. db_pool:0 active_threads:0")
      di.scan
    end
  end

  describe "#print_thread_dump" do
    it "can dump threads" do
      expect(described_class).to receive(:puts).with(/Thread: #<Thread:.*>/)
      expect(described_class).to receive(:puts).with(/backtrace/)
      described_class.print_thread_dump
    end

    it "can handle threads with a nil backtrace" do
      # The documentation calls out that the backtrace is an array or
      # nil.
      expect(described_class).to receive(:puts).with(/Thread: #<InstanceDouble.*>/)
      expect(described_class).to receive(:puts).with(nil)
      expect(Thread).to receive(:list).and_return([instance_double(Thread, backtrace: nil)])
      described_class.print_thread_dump
    end
  end

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
        s = Strand.create(prog: "Test", label: "synchronized")
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
      expect(described_class).to receive(:print_thread_dump)
      expect(Kernel).to receive(:exit!)

      Thread.new do
        th = Thread.current
        r, w = IO.pipe
        th.name = "clover_test"
        th[:clover_test_in] = r

        di.instance_variable_set(:@apoptosis_timeout, 0)
        di.instance_variable_set(:@dump_timeout, 0)
        Strand.create(prog: "Test", label: "wait_exit")
        di.start_cohort
        w.close
        di.threads.each(&:join)
      ensure
        Strand.truncate(cascade: true)
      end.join
    end
  end
end
