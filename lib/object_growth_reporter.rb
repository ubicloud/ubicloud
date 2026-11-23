# frozen_string_literal: true

require "objspace"

# Periodically logs which classes have the largest net increase in live
# objects (and in memory used by those objects), to help find memory growth
# and unintentional object retention in long running processes.
#
# The first report records a baseline (taken one interval after startup,
# so that most warmup allocation is excluded). Later reports show changes
# both since the previous report and since the baseline. Classes that keep
# showing up in the since-baseline lists across many reports are the best
# candidates for investigation. Slow, steady leaks are easier to see
# in the since-baseline lists, while the since-previous lists show
# short term churn.
#
# Each report runs a full GC and then walks the entire object heap, which
# holds the GVL for the duration (generally between 100ms and a few seconds,
# depending on heap size; reported as scan_seconds). This is disabled by
# default, and is designed to be enabled temporarily during investigations,
# with a fairly long interval (e.g. 600 seconds).
#
# To help determine whether memory growth is caused by Ruby objects, the
# reports also include changes in GC statistics (including the size of the
# Ruby object heap in heap_allocated_kb), YJIT memory usage, and process
# memory usage from /proc/self/smaps_rollup. Growth in smaps_rollup anonymous
# memory that is not matched by growth in heap_allocated_kb, live_memsize_bytes,
# or YJIT memory usage indicates memory allocated outside of Ruby objects
# (e.g. malloc fragmentation or C extension memory).
class ObjectGrowthReporter
  # Direct access to the shutdown queue. Only designed for use by the tests.
  attr_reader :shutdown_queue

  # Used to get the class of every object, including BasicObject instances
  # (e.g. Delegator) and objects that override #class (e.g. proxies).
  CLASS_OF = Kernel.instance_method(:class)

  # Used to get the name of classes, in case a class overrides .name.
  MODULE_NAME = Module.instance_method(:name)

  GC_STAT_KEYS = %i[
    heap_live_slots heap_free_slots heap_allocated_pages old_objects
    total_allocated_objects total_freed_objects minor_gc_count major_gc_count
    malloc_increase_bytes oldmalloc_increase_bytes
  ].freeze

  HEAP_PAGE_SIZE = GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE]

  # Fields to report from /proc/self/smaps_rollup (all in kB).
  SMAPS_ROLLUP_KEYS = {
    "Rss" => :rss,
    "Pss" => :pss,
    "Pss_Anon" => :pss_anon,
    "Pss_File" => :pss_file,
    "Shared_Clean" => :shared_clean,
    "Shared_Dirty" => :shared_dirty,
    "Private_Clean" => :private_clean,
    "Private_Dirty" => :private_dirty,
    "Anonymous" => :anonymous,
    "AnonHugePages" => :anon_huge_pages,
    "Swap" => :swap,
  }.freeze

  # Keys for hashes of numbers in snapshots, which have per-key changes reported.
  NUMERIC_HASH_KEYS = %i[gc yjit smaps_rollup_kb].freeze

  # Returns a reporter if reports are enabled for the given process type,
  # or nil if they are not enabled.
  def self.create_if_enabled
    interval = Config.object_growth_report_interval
    new(interval:) if interval.positive?
  end

  def initialize(interval:, top: Config.object_growth_report_top)
    @interval = interval
    @top = top
    @shutdown_queue = Queue.new
    @thread = nil
    @shutdown = false
    @report_number = 0
    @baseline = nil
    @previous = nil
  end

  # Stop the report loop and shutdown its thread, if it is running.
  def shutdown!
    # Make method idempotent
    return if @shutdown

    @shutdown = true
    @shutdown_queue.push(true)
    @thread&.join

    nil
  end

  # Start a thread that runs the run method. This thread will generally run
  # until shutdown! is called.
  def run_thread
    @thread = Thread.new do
      Thread.current.name = "object_growth_reporter"
      run
      true
    rescue => e
      Clog.emit("object growth reporter thread exiting due to unexpected error", Util.exception_to_hash(e))
      false
    end
  end

  # Report once per interval until shutdown! is called.
  def run
    until @shutdown_queue.pop(timeout: @interval)
      report
    end
  end

  # Take a snapshot of the object heap, and emit a log message comparing it
  # to the previous and baseline snapshots.
  def report
    @report_number += 1
    current = snapshot
    data = {
      report_number: @report_number,
      scan_seconds: current[:scan_seconds],
      rss_kb: current[:rss_kb],
      live_objects: current[:live_objects],
      live_memsize_bytes: current[:live_memsize_bytes],
      gc: current[:gc],
    }
    data[:yjit] = current[:yjit] if current[:yjit]
    data[:smaps_rollup_kb] = current[:smaps_rollup_kb] if current[:smaps_rollup_kb]

    if (baseline = @baseline)
      previous = @previous
      data[:seconds_since_baseline] = (current[:at] - baseline[:at]).round
      %i[rss_kb live_objects live_memsize_bytes].each do |key|
        data[:"#{key}_change_since_previous"] = difference(current[key], previous[key])
        data[:"#{key}_change_since_baseline"] = difference(current[key], baseline[key])
      end
      NUMERIC_HASH_KEYS.each do |key|
        if (change = hash_difference(current[key], previous[key]))
          data[:"#{key}_change_since_previous"] = change
        end
        if (change = hash_difference(current[key], baseline[key]))
          data[:"#{key}_change_since_baseline"] = change
        end
      end
      data[:top_class_count_increases_since_previous] = class_increases(current, previous, :counts)
      data[:top_class_count_increases_since_baseline] = class_increases(current, baseline, :counts)
      data[:top_class_memsize_increases_since_baseline] = class_increases(current, baseline, :memsizes)
      data[:top_type_count_increases_since_baseline] = increases(current[:types], baseline[:types])
      data[:top_data_type_count_increases_since_baseline] = increases(current[:data_types], baseline[:data_types])
    else
      # Nothing to compare against yet, so log the largest classes, to give
      # context for later reports.
      @baseline = current
      data[:baseline] = true
      data[:top_class_counts] = largest(current[:counts]).map { |name, count| {class: name, count:, memsize: current[:memsizes][name]} }
    end

    @previous = current
    Clog.emit("object growth", {object_growth: data})
  end

  # Gather the information needed for a report. Classes are identified
  # by name, so that snapshots do not retain anonymous classes.
  def snapshot
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    GC.start(full_mark: true, immediate_sweep: true)

    counts = Hash.new(0).compare_by_identity
    memsizes = Hash.new(0).compare_by_identity
    class_of = CLASS_OF
    ObjectSpace.each_object(BasicObject) do |obj|
      klass = class_of.bind_call(obj)
      counts[klass] += 1
      memsizes[klass] += ObjectSpace.memsize_of(obj)
    end

    named_counts = Hash.new(0)
    named_memsizes = Hash.new(0)
    counts.each do |klass, count|
      name = class_name(klass)
      named_counts[name] += count
      named_memsizes[name] += memsizes[klass]
    end

    data_types = {}
    ObjectSpace.count_tdata_objects.each do |type, count|
      data_types[type.is_a?(Class) ? class_name(type) : type.to_s] = count
    end

    gc = GC.stat.slice(*GC_STAT_KEYS)
    gc[:heap_allocated_kb] = (gc[:heap_allocated_pages] * HEAP_PAGE_SIZE) / 1024

    {
      at: Time.now,
      scan_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3),
      rss_kb:,
      live_objects: named_counts.each_value.sum,
      live_memsize_bytes: named_memsizes.each_value.sum,
      gc:,
      yjit:,
      smaps_rollup_kb:,
      counts: named_counts,
      memsizes: named_memsizes,
      types: ObjectSpace.count_objects.except(:TOTAL, :FREE),
      data_types:,
    }
  end

  private

  def class_increases(current, other, key)
    increases(current[key], other[key]).map do |entry|
      name = entry[:name]
      {
        class: name,
        count: current[:counts][name],
        count_change: difference(current[:counts][name], other[:counts][name]),
        memsize: current[:memsizes][name],
        memsize_change: difference(current[:memsizes][name], other[:memsizes][name]),
      }
    end
  end

  # The entries with the largest positive change between the hashes.
  def increases(current, other)
    changes = []
    current.each do |name, value|
      change = value - other.fetch(name, 0)
      changes << [name, change] if change > 0
    end
    changes.max_by(@top, &:last).map! { |name, change| {name:, count: current[name], change:} }
  end

  # Per-key changes between hashes of numbers, or nil if either hash is nil.
  def hash_difference(current, other)
    current.to_h { |key, value| [key, difference(value, other[key])] } if current && other
  end

  def largest(hash)
    hash.max_by(@top, &:last)
  end

  def difference(value, other)
    value - other if value && other
  end

  # Anonymous classes are grouped under their closest named superclass,
  # so that a process creating many anonymous classes produces a single
  # entry instead of many small entries.
  def class_name(klass)
    if (name = MODULE_NAME.bind_call(klass))
      return name
    end

    # This always terminates, as BasicObject is named.
    named = klass.superclass
    named = named.superclass until (name = MODULE_NAME.bind_call(named))
    "#<anonymous #{name}>"
  end

  def rss_kb
    File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1]&.to_i
  rescue SystemCallError
    nil
  end

  def smaps_rollup_kb
    smaps = {}
    File.read("/proc/self/smaps_rollup").scan(/^(\w+):\s+(\d+) kB$/) do |key, value|
      if (name = SMAPS_ROLLUP_KEYS[key])
        smaps[name] = value.to_i
      end
    end
    smaps unless smaps.empty?
  rescue SystemCallError
    nil
  end

  def yjit
    if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      {
        yjit_alloc_size: RubyVM::YJIT.runtime_stats(:yjit_alloc_size),
        code_region_size: RubyVM::YJIT.runtime_stats(:code_region_size),
      }
    end
  end
end
