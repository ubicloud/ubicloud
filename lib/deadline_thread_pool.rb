# frozen_string_literal: true

class DeadlineThreadPool
  DEFAULT_DEADLINE = 60 # seconds

  def initialize(size, job_deadline_seconds = DEFAULT_DEADLINE, max_jobs=1000)
    @size = size
    @job_deadline_seconds = job_deadline_seconds
    @jobs = SizedQueue.new(max_jobs)
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @running_deadlines = {}
  end

  def start
    return false if @jobs.closed?

    # Create worker threads
    @pool = Array.new(@size) do
      Thread.new do
        while (job = @jobs.pop)
          run_job(job)
        end
      end
    end

    # Start monitor thread
    @monitor = Thread.new do
      @mutex.synchronize do
        while !(@jobs.closed? && @jobs.empty? && @running_deadlines.empty?)
          wait_time = check_deadlines
          if wait_time.nil?
            @condition.wait(@mutex)
          else
            @condition.wait(@mutex, wait_time)
          end
        end
      end
    end

    true
  end

  def schedule(&block)
    raise ArgumentError, "Block required" unless block_given?
    @jobs << block
    self
  end

  def check_deadlines
    # This .values.min is the most dubiously expensive thing in this.
    return nil unless (earliest_deadline = @running_deadlines.values.min)
    now = Time.now
      
    # Check if any deadline is passed.
    Kernel.exit!(1) if earliest_deadline <= now

    # Return time until earliest deadline for next wakeup.
    [earliest_deadline - now, 0].max
  end

  def shutdown
    return if @jobs.closed?

    # Shut down worker threads, pop will return nil on a closed queue.
    @jobs.close

    # Wake up monitor thread to shut down, as they check @running.
    @mutex.synchronize { @condition.signal }

    # Join all threads
    @pool&.each(&:join)
    @monitor&.join

    @pool = nil
    @monitor = nil

    true
  end

  def run_job(job)
    deadline = Time.now + @job_deadline_seconds

    @mutex.synchronize do
      @running_deadlines[Thread.current] = deadline

      # Wake up monitor to check new deadline
      @condition.signal 
    end

    job.call
  rescue
    puts "Job failed: #{$!.full_message}"
  ensure
    @mutex.synchronize do
      @running_deadlines.delete(Thread.current)
      @condition.signal
    end
  end
end
