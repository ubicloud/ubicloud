# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  after do
    di.shutdown_and_cleanup_threads
    Thread.current.name = nil
  end

  describe "#shutdown" do
    it "sets shutting_down flag" do
      expect { di.shutdown }.to change(di, :shutting_down).from(false).to(true)

      # Test idempotent behavior
      2.times { di.shutdown_and_cleanup_threads }
    end
  end

  describe "#num_current_strands" do
    it "returns the number of current strands being handled" do
      expect(di.num_current_strands).to eq 0
      di.instance_variable_get(:@current_strands)["a"] = true
      expect(di.num_current_strands).to eq 1
    end
  end

  describe "#scan" do
    it "returns empty array if there are no strands ready for running" do
      expect(di.scan).to eq([])
    end

    it "returns array of strands ready for running" do
      Strand.create(prog: "Test", label: "wait_exit")
      st = Strand.first
      expect(di.scan).to eq([])
      st.update(schedule: Time.now + 10)
      expect(di.scan).to eq([])
      st.update(schedule: Time.now - 10)
      expect(di.scan.map(&:id)).to eq([st.id])
    end

    it "returns empty array when shutting down" do
      di.shutdown
      expect(di.scan).to eq([])
    end
  end

  describe "#apoptosis_run" do
    it "does not trigger exit if strand runs on time" do
      expect(ThreadPrinter).not_to receive(:run)
      expect(Kernel).not_to receive(:exit!)
      start_queue = Queue.new
      finish_queue = Queue.new
      start_queue.push(true)
      finish_queue.push(true)
      expect(di.apoptosis_run(0, start_queue, finish_queue)).to be true
    end
  end

  describe "#apoptosis_thread" do
    it "triggers thread dumps and exit if the Prog takes too long" do
      exited = false
      expect(ThreadPrinter).to receive(:run)
      expect(Kernel).to receive(:exit!).and_invoke(-> { exited = true })
      di = described_class.new(apoptosis_timeout: 0.05, pool_size: 1)
      start_queue = di.instance_variable_get(:@thread_data).dig(0, :start_queue)
      start_queue.push(true)
      t = Time.now
      until exited
        raise "no apoptosis within 1 second" if Time.now - t > 1
        sleep 0.1
      end
      expect(exited).to be true
    end

    it "triggers thread dumps and exit if the there is an exception raised" do
      exited = false
      expect(ThreadPrinter).to receive(:run)
      expect(Kernel).to receive(:exit!).and_invoke(-> { exited = true })
      di = described_class.new(apoptosis_timeout: 0.05, pool_size: 1)
      thread_data = di.instance_variable_get(:@thread_data)
      start_queue = thread_data.dig(0, :start_queue)
      finish_queue = thread_data.dig(0, :finish_queue)
      finish_queue.singleton_class.undef_method(:pop)
      start_queue.push(true)
      t = Time.now
      until exited
        raise "no apoptosis within 1 second" if Time.now - t > 1
        sleep 0.1
      end
      expect(exited).to be true
    end
  end

  describe "#start_cohort" do
    it "returns true if there are no strands" do
      expect(di.start_cohort).to be true
      expect(di.instance_variable_get(:@strand_queue).pop(timeout: 0)).to be_nil
      expect(di.instance_variable_get(:@current_strands)).to be_empty
    end

    it "returns false if the dispatcher is shutting down after the scan" do
      Strand.create(prog: "Test", label: "wait_exit", schedule: Time.now - 10)
      expect(di).to receive(:scan).and_wrap_original do |original_method|
        res = original_method.call
        di.shutdown
        res
      end
      expect(di.start_cohort).to be false
      expect(di.instance_variable_get(:@strand_queue).pop(timeout: 0)).to be_nil
      expect(di.instance_variable_get(:@current_strands)).to be_empty
    end

    it "returns true if the dispatcher is shutting down and there are no strands" do
      di.shutdown
      expect(di.start_cohort).to be true
      expect(di.instance_variable_get(:@strand_queue).pop(timeout: 0)).to be_nil
      expect(di.instance_variable_get(:@current_strands)).to be_empty
    end

    it "returns false and pushes to strand queue if there are strands" do
      st = Strand.create(prog: "Test", label: "wait_exit", schedule: Time.now - 10)
      old_queue = di.instance_variable_get(:@strand_queue)
      new_queue = di.instance_variable_set(:@strand_queue, Queue.new)
      expect(di.start_cohort).to be false
      expect(new_queue.pop(true).id).to eq st.id
      expect(di.instance_variable_get(:@current_strands)).to eq(st.id => true)

      # Check that we don't retrieve strands currently executing
      di.instance_variable_set(:@strand_queue, old_queue)
      expect(di.start_cohort).to be true
      expect(di.instance_variable_get(:@current_strands)).to eq(st.id => true)
    end
  end

  describe "#run_strand" do
    it "runs strand" do
      Strand.create(prog: "Test", label: "napper", schedule: Time.now - 10)
      st = di.scan.first
      start_queue = Queue.new
      finish_queue = Queue.new
      current_strands = di.instance_variable_get(:@current_strands)
      current_strands[st.id] = true
      session = instance_double(Net::SSH::Connection::Session)
      expect(session).to receive(:close).and_raise(RuntimeError)
      Thread.current[:clover_ssh_cache] = {nil => session}
      expect(di.run_strand(st, start_queue, finish_queue)).to be_a(Prog::Base::Nap)
      expect(start_queue.pop(true)).to eq st.ubid
      expect(finish_queue.pop(true)).to be true
      expect(current_strands).to be_empty
      expect(Thread.current[:clover_ssh_cache]).to be_empty
    end

    it "print exceptions if they are raised" do
      ex = begin
        begin
          raise StandardError.new("nested test error")
        rescue
          raise StandardError.new("outer test error")
        end
      rescue => ex
        ex
      end

      st = Strand.create(prog: "Test", label: "wait_exit", schedule: Time.now - 10)
      expect(st).to receive(:run).and_raise(ex)

      # Go to the trouble of emitting those exceptions to provoke
      # plausible crashes in serialization.
      expect(Config).to receive(:test?).and_return(false).twice
      expect($stdout).to receive(:write).with(a_string_matching(/outer test error/))
      expect($stdout).to receive(:write).with(a_string_matching(/nested test error/))

      start_queue = Queue.new
      finish_queue = Queue.new
      current_strands = di.instance_variable_get(:@current_strands)
      current_strands[st.id] = true
      expect(di.run_strand(st, start_queue, finish_queue)).to eq ex
      expect(start_queue.pop(true)).to eq st.ubid
      expect(finish_queue.pop(true)).to be true
      expect(current_strands).to be_empty
    end
  end
end
