# frozen_string_literal: true

require "json"

# Checks a runner metrics entry that a guest wrote, as a JSON object of
# exactly KEYS. The guest controls every byte of it, so anything else is
# treated as an attack by the callers.
module RunnerMetricsEntry
  class Invalid < StandardError; end

  MAX_SIZE = 4096
  MAX_AGE = 60 * 60
  MAX_CLOCK_SKEW = 60
  MAX_VALUE = 2**53
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

  # Returns the entry parsed from text, named in errors by name. Sets text's
  # encoding to UTF-8, so callers pass a string they own.
  def self.parse(text, name)
    text.force_encoding(Encoding::UTF_8)
    fail Invalid, "#{name} is not valid UTF-8" unless text.valid_encoding?
    fail Invalid, "#{name} is longer than #{MAX_SIZE} bytes" if text.bytesize > MAX_SIZE

    entry = begin
      JSON.parse(text, max_nesting: 1)
    rescue JSON::ParserError => ex
      raise Invalid, "#{name} is not a JSON object: #{ex.message}"
    end
    fail Invalid, "#{name} does not have the expected keys" unless entry.is_a?(Hash) && entry.keys == KEYS

    seq = entry["seq"]
    fail Invalid, "#{name} has seq #{seq.inspect}" unless seq.is_a?(Integer) && seq > 0
    fail Invalid, "#{name} has time #{entry["time"].inspect}" unless entry["time"].is_a?(Integer)

    METRICS.each do |metric|
      value = entry[metric]
      max = PERCENT_METRICS.include?(metric) ? 100 : MAX_VALUE
      unless value.is_a?(Numeric) && value.finite? && value >= 0 && value <= max
        fail Invalid, "#{name} has #{metric} #{value.inspect}"
      end
    end

    entry
  end

  # Checks that a new entry's time is close to now.
  def self.check_time(entry, now)
    times = (now.to_i - MAX_AGE)..(now.to_i + MAX_CLOCK_SKEW)
    fail Invalid, "seq #{entry["seq"]} has time #{entry["time"]}, outside #{times}" unless times.cover?(entry["time"])
  end
end
