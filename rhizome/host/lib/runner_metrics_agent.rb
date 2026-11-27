# frozen_string_literal: true

require "json"

# Copies new samples from a runner VM's metrics disk, a ring of JSON lines
# padded to SLOT_SIZE, into JSON lines files. The guest controls the disk, so
# every slot is validated, and invalid data is treated as an attack.
class RunnerMetricsAgent
  class InvalidData < StandardError; end

  SLOT_SIZE = 4096
  EMPTY_SLOT = ("\0" * SLOT_SIZE).b.freeze
  MAX_FILES = 120
  MAX_AGE = 60 * 60
  MAX_CLOCK_SKEW = 60
  MAX_VALUE = 2**53
  RETRY_DELAY = 1
  PERCENT_METRICS = %w[
    runner_cpu_load_user runner_cpu_load_nice runner_cpu_load_system runner_cpu_load_iowait runner_cpu_load_steal
    runner_filesystems_fsused_percent
  ].freeze
  KEYS = %w[
    seq time
    runner_cpu_load_user runner_cpu_load_nice runner_cpu_load_system runner_cpu_load_iowait runner_cpu_load_steal
    runner_queue_ldavg_1 runner_queue_ldavg_5 runner_queue_ldavg_15
    runner_memory_memused runner_memory_avail runner_memory_cached
    runner_filesystems_fsused_percent
    runner_disk_rkb runner_disk_wkb
    runner_net_dev_rxkb runner_net_dev_txkb
  ].freeze
  METRICS = (KEYS - %w[seq time]).freeze

  def initialize(disk, out_dir)
    @disk = disk
    @disk_size = disk.size
    @slot_count = @disk_size / SLOT_SIZE
    @out_dir = out_dir
    @last_seq = 0
  end

  # Returns [seq, entry] pairs of the written slots, ordered by seq.
  def entries(buffer)
    fail InvalidData, "the metrics disk is #{buffer.bytesize} bytes, not #{@disk_size}" unless buffer.bytesize == @disk_size

    found = []
    @slot_count.times do |index|
      slot = buffer.byteslice(index * SLOT_SIZE, SLOT_SIZE)
      found << parse_slot(slot, index) unless slot == EMPTY_SLOT
    end
    found.sort_by!(&:first)
  end

  def parse_slot(slot, index)
    slot.force_encoding(Encoding::UTF_8)
    fail InvalidData, "slot #{index} is not valid UTF-8" unless slot.valid_encoding?
    fail InvalidData, "slot #{index} does not end with a newline" unless slot.end_with?("\n")

    entry = begin
      JSON.parse(slot, max_nesting: 1)
    rescue JSON::ParserError => ex
      raise InvalidData, "slot #{index} is not a JSON object: #{ex.message}"
    end
    fail InvalidData, "slot #{index} does not have the expected keys" unless entry.is_a?(Hash) && entry.keys == KEYS

    seq = entry["seq"]
    fail InvalidData, "slot #{index} has seq #{seq.inspect}" unless seq.is_a?(Integer) && seq > 0 && seq % @slot_count == index
    fail InvalidData, "slot #{index} has time #{entry["time"].inspect}" unless entry["time"].is_a?(Integer)

    METRICS.each do |metric|
      value = entry[metric]
      max = PERCENT_METRICS.include?(metric) ? 100 : MAX_VALUE
      unless value.is_a?(Numeric) && value.finite? && value >= 0 && value <= max
        fail InvalidData, "slot #{index} has #{metric} #{value.inspect}"
      end
    end

    [seq, entry]
  end

  def read_entries
    entries(@disk.pread(@disk_size, 0))
  rescue InvalidData
    # A slot read while the guest writes it can be torn, so read the disk
    # again before treating it as an attack.
    sleep RETRY_DELAY
    entries(@disk.pread(@disk_size, 0))
  end

  # Writes the samples newer than the last written one into a file named by
  # the newest seq, so the files are reused rather than cleaned up.
  def tick(now = Time.now)
    found = read_entries
    return 0 if found.empty?

    newest_seq = found.last.first
    fail InvalidData, "newest seq went back from #{@last_seq} to #{newest_seq}" if newest_seq < @last_seq

    fresh = found.select { |seq, _| seq > @last_seq }
    return 0 if fresh.empty?

    times = (now.to_i - MAX_AGE)..(now.to_i + MAX_CLOCK_SKEW)
    fresh.each do |seq, entry|
      fail InvalidData, "seq #{seq} has time #{entry["time"]}, outside #{times}" unless times.cover?(entry["time"])
    end

    path = "#{@out_dir}/#{newest_seq % MAX_FILES}.jsonl"
    tmp_path = "#{path}.tmp"
    File.open(tmp_path, "w") do |f|
      fresh.each do |_, entry|
        entry.delete("seq")
        f.puts(JSON.generate(entry))
      end
    end
    File.rename(tmp_path, path)
    @last_seq = newest_seq
    fresh.size
  end

  def run(interval: 5)
    loop do
      tick
      sleep interval
    end
  end
end
