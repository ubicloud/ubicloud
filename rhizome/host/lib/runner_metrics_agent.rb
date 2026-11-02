# frozen_string_literal: true

require "fileutils"
require "json"

# Copies new samples from a runner VM's metrics disk, a ring of
# {"seq":<n>,"sysstat":{...}} lines padded to SLOT_SIZE, into JSON lines files.
class RunnerMetricsAgent
  SLOT_SIZE = 4096
  MAX_FILES = 120
  MAX_NESTING = 10
  FILE_TIME_FORMAT = "%Y%m%dT%H%M%S%N"

  def initialize(disk_path, out_dir)
    @disk_path = disk_path
    @out_dir = out_dir
    @last_seq = 0
    FileUtils.mkdir_p(done_dir)
  end

  def done_dir
    "#{@out_dir}/done"
  end

  def entries(buffer)
    found = (buffer.bytesize / SLOT_SIZE).times.filter_map do |index|
      slot = buffer.byteslice(index * SLOT_SIZE, SLOT_SIZE).force_encoding(Encoding::UTF_8)
      next unless slot.start_with?("{") && slot.end_with?("\n")

      entry = begin
        JSON.parse(slot, max_nesting: MAX_NESTING)
      rescue JSON::ParserError
        next
      end
      next unless entry.is_a?(Hash) && (seq = entry["seq"]).is_a?(Integer) && seq > 0 && entry["sysstat"].is_a?(Hash)

      [seq, JSON.generate(entry)]
    end
    found.sort_by!(&:first)
  end

  def tick(now = Time.now)
    found = entries(File.binread(@disk_path))
    # A lower newest seq means the VM restarted with a zeroed disk.
    @last_seq = 0 if found.any? && found.last.first < @last_seq
    fresh = found.select { |seq, _| seq > @last_seq }
    return 0 if fresh.empty?

    # Not safe_write_to_file: it leaves a .tmp.lock behind for each file name.
    path = "#{done_dir}/#{now.utc.strftime(FILE_TIME_FORMAT)}.jsonl"
    File.write("#{path}.tmp", fresh.map { |_, line| "#{line}\n" }.join)
    File.rename("#{path}.tmp", path)
    @last_seq = fresh.last.first

    Dir.children(done_dir).select { |file| file.end_with?(".jsonl") }.sort[0...-MAX_FILES].each { |file| File.delete("#{done_dir}/#{file}") }
    fresh.count
  end

  def run(interval: 5)
    loop do
      tick
      sleep interval
    end
  end
end
