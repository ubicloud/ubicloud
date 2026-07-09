# frozen-string-literal: true

class GcStatsReporter
  # GC.stat entries that separate Ruby heap growth (heap_live_slots,
  # old_objects) from allocation pressure and native memory growth
  # (malloc_increase_bytes, oldmalloc_increase_bytes).
  GC_STAT_KEYS = %i[
    count
    minor_gc_count
    major_gc_count
    heap_live_slots
    heap_free_slots
    old_objects
    total_allocated_objects
    malloc_increase_bytes
    oldmalloc_increase_bytes
  ].freeze

  # key :: Clog.emit key to use
  # report_every :: the number of seconds between reports
  # status_file :: file to read process RSS and swap usage from
  def initialize(key: "#{ENV["PROCESS_TYPE"]}_gc_stats", report_every: 60, status_file: "/proc/self/status")
    @key = key
    @message = key.tr("_", " ").freeze
    @report_every = report_every
    @status_file = status_file
    @queue = Queue.new
    @thread = nil
    @shutdown = false
  end

  # Stop reporting and shutdown the reporting thread, if it is running.
  def shutdown!
    # Make method idempotent
    return if @shutdown

    @shutdown = true

    @queue.push(nil)

    @thread&.join

    nil
  end

  # Start a thread that runs the run method. This thread will generally run
  # until shutdown! is called.
  def run_thread
    @thread = Thread.new do
      run
      true
    rescue => e
      Clog.emit("#{@key} failure", Util.exception_to_hash(e))
      false
    end
  end

  # Emit GC and process memory statistics every report_every seconds until
  # shutdown! is called.
  def run
    until @shutdown
      Clog.emit(@message, {@key => stats})
      @queue.pop(timeout: @report_every)
    end
  end

  # A hash of the current GC statistics and process memory usage.
  def stats
    stat = GC.stat
    data = GC_STAT_KEYS.to_h { [it.to_s, stat[it]] }
    data["pid"] = Process.pid

    if File.file?(@status_file)
      File.foreach(@status_file) do |line|
        if (md = /\AVm(RSS|Swap):\s+(\d+) kB/.match(line))
          data["#{md[1].downcase}_kb"] = md[2].to_i
        end
      end
    end

    data
  end
end
