# frozen_string_literal: true

require "json"
require_relative "../../common/lib/runner_metrics_entry"

# Copies new samples from a runner VM's metrics disk, a ring of JSON lines
# padded to SLOT_SIZE, into JSON lines files. The guest controls the disk, so
# every slot is validated, and invalid data is treated as an attack.
class RunnerMetricsAgent
  SLOT_SIZE = 4096
  EMPTY_SLOT = ("\0" * SLOT_SIZE).b.freeze
  MAX_FILES = 120
  RETRY_DELAY = 1

  def initialize(disk, out_dir)
    @disk = disk
    @disk_size = disk.size
    @slot_count = @disk_size / SLOT_SIZE
    @out_dir = out_dir
    @last_seq = 0
  end

  # Returns [seq, entry] pairs of the written slots, ordered by seq.
  def entries(buffer)
    fail RunnerMetricsEntry::Invalid, "the metrics disk is #{buffer.bytesize} bytes, not #{@disk_size}" unless buffer.bytesize == @disk_size

    found = []
    @slot_count.times do |index|
      slot = buffer.byteslice(index * SLOT_SIZE, SLOT_SIZE)
      found << parse_slot(slot, index) unless slot == EMPTY_SLOT
    end
    found.sort_by!(&:first)
  end

  def parse_slot(slot, index)
    fail RunnerMetricsEntry::Invalid, "slot #{index} does not end with a newline" unless slot.end_with?("\n")

    entry = RunnerMetricsEntry.parse(slot, "slot #{index}")
    seq = entry["seq"]
    fail RunnerMetricsEntry::Invalid, "slot #{index} has seq #{seq}" unless seq % @slot_count == index

    [seq, entry]
  end

  def read_entries
    entries(@disk.pread(@disk_size, 0))
  rescue RunnerMetricsEntry::Invalid
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
    fail RunnerMetricsEntry::Invalid, "newest seq went back from #{@last_seq} to #{newest_seq}" if newest_seq < @last_seq

    fresh = found.select { |seq, _| seq > @last_seq }
    return 0 if fresh.empty?

    fresh.each { |_, entry| RunnerMetricsEntry.check_time(entry, now) }

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
