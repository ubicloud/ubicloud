# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  after do
    (@di || di).shutdown_and_cleanup_threads
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

    it "does not include strands outside of partition" do
      st = Strand.create(prog: "Test", label: "wait_exit")
      id = "00000000-0000-0000-0000-000000000000"
      di = @di = described_class.new(partition: id..id)
      st.update(schedule: Time.now - 10)
      expect(di.scan.map(&:id)).to eq([])
    end

    it "includes strands inside of partition" do
      st = Strand.create(prog: "Test", label: "wait_exit")
      di = @di = described_class.new(partition: st.id..st.id)
      st.update(schedule: Time.now - 10)
      expect(di.scan.map(&:id)).to eq([st.id])
    end

    it "returns empty array when shutting down" do
      di.shutdown
      expect(di.scan).to eq([])
    end
  end

  describe "#scan_old" do
    it "returns empty array for non-partitioned dispatcher" do
      expect(di.scan_old).to eq([])
    end

    it "returns empty array when shutting down" do
      id = "00000000-0000-0000-0000-000000000000"
      di = @di = described_class.new(partition: id..id)
      di.shutdown
      expect(di.scan_old).to eq([])
    end

    it "includes strands outside of partition" do
      st = Strand.create(prog: "Test", label: "wait_exit")
      id = "00000000-0000-0000-0000-000000000000"
      di = @di = described_class.new(partition: id..id)
      st.update(schedule: Time.now - 3)
      expect(di.scan_old.map(&:id)).to eq([])
      st.update(schedule: Time.now - 7)
      expect(di.scan_old.map(&:id)).to eq([st.id])
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
      di = @di = described_class.new(apoptosis_timeout: 0.05, pool_size: 1)
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
      di = @di = described_class.new(apoptosis_timeout: 0.05, pool_size: 1)
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
    it "accepts an array of strands" do
      expect(di.start_cohort([])).to be true
      expect(di.instance_variable_get(:@strand_queue).pop(timeout: 0)).to be_nil
      expect(di.instance_variable_get(:@current_strands)).to be_empty
    end

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

  describe "#metrics_thread" do
    it "emits metrics every 1000 queue entries" do
      q = Queue.new
      1000.times { q.push 1 }
      q.push nil
      expect(di).to receive(:metrics_hash).with([1] * 1000).and_return({})
      expect(Clog).to receive(:emit).and_call_original
      di.metrics_thread(q)
    end
  end

  describe "#metrics_hash" do
    it "takes array of Strand::RespirateMetrics and returns hash of metric information" do
      t = Time.now
      arrays = []
      rm = Strand::RespirateMetrics
      arrays << Array.new(750) { rm.new(t, t + 1, t + 2, t + 3, true, 0, 0) }
      arrays << Array.new(100) { rm.new(t, t + 2, t + 4, t + 7, true, 10, 9) }
      arrays << Array.new(100) { rm.new(t, t + 3, t + 8, t + 12, true, 20, 7) }
      arrays << Array.new(40) { rm.new(t, t + 5, t + 12, t + 21, false, 30, 5) }
      arrays << Array.new(9) { rm.new(t, t + 6, t + 16, t + 29, true, 40, 3) }
      arrays << Array.new(1) { rm.new(t, t + 7, t + 20, t + 37, false, 50, 1) }
      expect(di.metrics_hash(arrays.flatten)).to eq({
        available_workers: {average: 1, max: 9, median: 0, p75: 1, p85: 7, p95: 9, p99: 9},
        lease_acquire_percentage: 95.9,
        lease_delay: {average: 1.944, max: 17.0, median: 1.0, p75: 3.0, p85: 4.0, p95: 9.0, p99: 13.0},
        queue_delay: {average: 1.833, max: 13.0, median: 1.0, p75: 2.0, p85: 5.0, p95: 7.0, p99: 10.0},
        queue_size: {average: 4, max: 50, median: 0, p75: 10, p85: 20, p95: 30, p99: 40},
        scan_delay: {average: 1.511, max: 7.0, median: 1.0, p75: 2.0, p85: 3.0, p95: 5.0, p99: 6.0}
      })
    end
  end

  describe "#strand_thread" do
    it "runs strands pushed onto queue" do
      Strand.create(prog: "Test", label: "napper", schedule: Time.now - 10)
      st = di.scan.first
      strand_queue = Queue.new
      start_queue = Queue.new
      finish_queue = Queue.new
      current_strands = di.instance_variable_get(:@current_strands)
      current_strands[st.id] = true
      session = instance_double(Net::SSH::Connection::Session)
      expect(session).to receive(:close).and_raise(RuntimeError)
      Thread.current[:clover_ssh_cache] = {nil => session}
      strand_queue.push(st)
      strand_queue.push(nil)
      expect(di.strand_thread(strand_queue, start_queue, finish_queue)).to be_nil
      expect(Time.now - st.respirate_metrics.worker_started).to be_within(1).of(0)
      expect(st.respirate_metrics.queue_size).to eq 1
      expect(st.respirate_metrics.available_workers).to eq 0
      expect(start_queue.pop(true)).to eq st.ubid
      expect(start_queue.pop(true)).to be_nil
      expect(finish_queue.pop(true)).to be true
      expect(current_strands).to be_empty
      expect(Thread.current[:clover_ssh_cache]).to be_empty
    end
  end

  describe "#run_strand" do
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
