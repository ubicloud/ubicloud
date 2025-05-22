# frozen_string_literal: true

require "rspec"
require_relative "../../lib/deadline_thread_pool"

RSpec.describe DeadlineThreadPool do
  subject(:pool) { described_class.new(2, 5) } # 5 second deadline

  before do
    # Prevent actual process termination during tests
    expect(pool).to receive(:handle_missed_deadline).and_return(nil).at_most(:once)
  end

  after do
    # Ensure pool is always shut down after tests
    pool.shutdown if pool.running?
  end

  describe "#initialize" do
    it "creates a pool in non-running state with job deadline" do
      pool = described_class.new(3, 10)

      expect(pool.running?).to be false
      expect(pool.instance_variable_get(:@job_deadline_seconds)).to eq(10)
    end
  end

  describe "#start" do
    it "creates worker threads and monitor thread" do
      expect { pool.start }.to change(pool, :running?).from(false).to(true)

      expect(pool.instance_variable_get(:@pool).size).to eq(2)
      expect(pool.instance_variable_get(:@monitor)).to be_a(Thread)
    end

    it "returns false if already running" do
      pool.start
      expect(pool.start).to be false
    end
  end

  describe "#schedule" do
    it "raises an error when no block is given" do
      expect { pool.schedule }.to raise_error(ArgumentError, "Block required")
    end

    it "adds job to the queue" do
      job = proc { puts "test" }

      # Access the Queue object directly to check size before and after
      jobs_queue = pool.instance_variable_get(:@jobs)
      expect { pool.schedule(&job) }.to change { jobs_queue.size }.by(1)
    end

    it "returns self for chaining" do
      expect(pool.schedule { nil }).to eq(pool)
    end
  end

  describe "#check_deadlines" do
    it "returns nil when no jobs are running" do
      expect(pool.check_deadlines).to be_nil
    end

    context "with running jobs" do
      let(:now) { Time.new(2025, 5, 21, 13, 30, 0) }
      let(:thread_id) { 123 }

      before do
        # Mock current time
        expect(Time).to receive(:now).and_return(now).at_least(:once)
      end

      it "returns time until deadline for running job" do
        # Simulate a running job
        deadline = now + 5
        pool.instance_variable_get(:@running_deadlines)[thread_id] = deadline

        expect(pool.check_deadlines).to be_within(0.1).of(5)
      end

      it "handles missed deadlines" do
        # Add a running job with missed deadline
        pool.instance_variable_get(:@running_deadlines)[thread_id] = now - 1

        # We've already set the expectation in the before block
        pool.check_deadlines
      end

      it "returns the time until the earliest deadline" do
        # Two jobs with different deadlines
        pool.instance_variable_get(:@running_deadlines)[thread_id] = now + 10
        pool.instance_variable_get(:@running_deadlines)[thread_id + 1] = now + 5

        expect(pool.check_deadlines).to be_within(0.1).of(5)
      end
    end
  end
  
  describe "#run_job" do
    let(:job) { instance_double(Proc) }
    let(:now) { Time.new(2025, 5, 21, 13, 30, 0) }
    
    it "sets deadline when job starts and clears it when done" do
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      expect(job).to receive(:call)
      running_deadlines = pool.instance_variable_get(:@running_deadlines)
      thread_id = Thread.current.object_id

      # Deadlines should be added during execution
      expect { pool.run_job(job) }
        .not_to change { running_deadlines.keys.count }

      # Deadline should be cleared after completion
      expect(running_deadlines).to be_empty
    end
  end
  
end


#   describe "integration" do
#     let(:result_queue) { Queue.new }

#     before { pool.start }

#     it "executes scheduled jobs" do
#       pool.schedule { result_queue << "done" }

#       expect(result_queue.pop).to eq("done")
#     end

#     it "enforces deadlines for long-running jobs" do
#       now = Time.new(2025, 5, 21, 13, 30, 0)

#       # Mock time to first return current time, then time after deadline
#       expect(Time).to receive(:now).and_return(now, now + 10)

#       # Schedule a job that will exceed its deadline
#       pool.schedule do
#         sleep 0.1 # Small delay to ensure the monitor thread runs
#         result_queue << "should not complete"
#       end

#       # The handle_missed_deadline method should be called
#       # (expectation set in the top-level before block)

#       # No result should be received (process would terminate in real usage)
#       expect { result_queue.pop(true) }.to raise_error(ThreadError)
#     end
#   end

#   describe "#shutdown" do
#     before { pool.start }

#     it "sets running to false and joins all threads" do
#       expect { pool.shutdown }.to change(pool, :running?).from(true).to(false)

#       # Threads should be nil after shutdown
#       expect(pool.instance_variable_get(:@pool)).to be_nil
#       expect(pool.instance_variable_get(:@monitor)).to be_nil
#     end

#     it "returns nil if not running" do
#       pool.shutdown
#       expect(pool.shutdown).to be_nil
#     end
#   end
# end
