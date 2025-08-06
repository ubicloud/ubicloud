# frozen_string_literal: true

class Repartitioner
  attr_reader :strand_id_range

  attr_accessor :repartitioned

  def initialize(partition_number:, channel:, listen_timeout:, recheck_seconds:, stale_seconds:, max_partition:)
    @partition_number = partition_number

    # Assume when starting that we are the final partition. For cases where we aren't,
    # this will quickly be updated after startup.
    @num_partitions = partition_number

    # Used for NOTIFY, since NOTIFY payload must be a string
    @partition_number_string = partition_number.to_s

    # Flag set when we have repartitioned, to ensure we do a scan using the new partition
    # before enqueuing additional resources.
    @repartitioned = true

    # This starts out empty, but will be filled in by notifications from the current
    # process and other processes listening on the same channel.
    @partition_times = {}

    # Check for shutdown every second
    @listen_timeout = listen_timeout

    # Check for stale partitions and notify that the current process is still running
    # every 18 seconds.
    @recheck_seconds = recheck_seconds

    # Remove a partition if we have not been notified about it in the given number of seconds.
    # Combined with the above two settings, this means that if the final partition
    # process exits, other processes will repartition in at most
    # listen_timeout + recheck_seconds + stale_seconds seconds.
    @stale_seconds = stale_seconds

    # The next deadline after which to check for stale partitions and notify.
    @partition_recheck_time = Time.now + recheck_seconds - rand

    # The channel to LISTEN and NOTIFY on.
    @channel = channel

    # The maximum partition we will consider valid.
    @max_partition = max_partition

    # Message to emit when repartitioning
    @repartition_emit_message = "#{@channel} repartitioning"

    # Top level key used in emit json when repartitioning
    @repartition_emit_key = :"#{@channel}_repartition"

    @shutdown = false

    repartition(partition_number)
  end

  def shutdown!
    @shutdown = true
  end

  # Notify the channel that we exist, so that other processes
  # can repartition appropriately if needed.
  def notify
    DB.notify(@channel, payload: @partition_number_string)
  end

  # Listens on the channel to determine what other processes are
  # running, and updates the num_partitions information, so that the current process
  # scan thread will use the appropriate partition.
  def listen
    # If the maximum partition number after rechecking is lower than the currently
    # expected partitioning, repartition the current process to expand the
    # partition size.
    loop = proc do
      if (max_partition = repartition_check)&.<(@num_partitions)
        repartition(max_partition)
      end
    end

    allowed_partition_range = 1..@max_partition
    emit_str = "invalid #{@channel} repartition notification"
    emit_key = :"#{@channel}_notify_payload"

    # Continuouly LISTENs for notifications on the channel until shutdown.
    # If notified about a higher partition number than the currently expected
    # partitioning, repartition the current process to decrease the partition size.
    DB.listen(@channel, loop:, after_listen: proc { notify }, timeout: @listen_timeout) do |_, _, payload|
      throw :stop if @shutdown

      unless (notify_partition_num = Integer(payload, exception: false)) && allowed_partition_range.cover?(notify_partition_num)
        Clog.emit(emit_str) { {emit_key => payload} }
        next
      end

      repartition(notify_partition_num) if notify_partition_num > @num_partitions
      @partition_times[notify_partition_num] = Time.now
    end
  end

  private

  def partition_boundary(partition_num, partition_size)
    "%08x-0000-0000-0000-000000000000" % (partition_num * partition_size).to_i
  end

  # This calculates the partition of the id space that this process will operate on.
  def calculate_strand_id_range
    partition_size = (16**8) / @num_partitions.to_r
    start_id = partition_boundary(@partition_number - 1, partition_size)

    @strand_id_range = if @num_partitions == @partition_number
      start_id.."ffffffff-ffff-ffff-ffff-ffffffffffff"
    else
      start_id...partition_boundary(@partition_number, partition_size)
    end
  end

  # Updates the total number of partitions, and sets the repartition flag, so the
  # next main loop iteration will run a scan query.
  def repartition(np)
    @num_partitions = np
    calculate_strand_id_range
    @repartitioned = true
    Clog.emit(@repartition_emit_message) {
      {@repartition_emit_key => {
        partition_number: @partition_number,
        num_partitions: np,
        range: @strand_id_range
      }}
    }
  end

  # Called every second. Used to exit the listen loop on shutdown, and to NOTIFY
  # about the current process and remove stale processes when rechecking.
  def repartition_check
    throw :stop if @shutdown

    t = Time.now
    if t > @partition_recheck_time
      @partition_recheck_time = t + @recheck_seconds
      notify
      stale = t - @stale_seconds
      @partition_times.reject! { |_, time| time < stale }
      @partition_times.keys.max
    end
  end
end
