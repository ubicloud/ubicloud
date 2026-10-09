# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/util"

class IoThrottle
  IMMUNE_PATTERNS = [
    "archiver",     # Its progress resolves the archival backlog
    "logger",       # Throttling affects archiver (logs go to stderr)
    "checkpointer", # Checkpoints trigger WAL deletion
    "writer",        # wal writer + background writer - allow checkpoints to complete
  ].freeze

  # Throttle ratios applied to the provider's disk throughput baseline.
  # At each tier, postgres I/O is capped to this fraction of baseline, leaving
  # the remainder for the archiver (which is exempt from throttling).
  IO_THROTTLE_RATIOS = [
    [1000, 0.20],  # Critical: 1000+ files -> 20% of baseline
    [500, 0.50],   # Severe: 500-999 files -> 50% of baseline
    [100, 0.80],    # Moderate: 100-499 files -> 80% of baseline
  ].freeze

  # Wait for specified replication slots to connect.
  # Throttle slots which didn't connect within SLOT_WAIT_GRACE seconds,
  # for up to the SLOT_WAIT_MAX_AGE seconds.
  SLOT_WAIT_DIR = "/run/postgresql-slot-wait"
  SLOT_WAIT_GRACE = 60
  SLOT_WAIT_MAX_AGE = 5 * 60
  SLOT_WAIT_RATIO = 0.2

  def self.signal_slot_wait(slot_name)
    FileUtils.mkdir_p(SLOT_WAIT_DIR)
    FileUtils.touch(File.join(SLOT_WAIT_DIR, "#{slot_name}.wait_signal"))
  end

  def initialize(instance, logger, disk_throughput_baseline_mbps)
    @instance = instance
    @logger = logger
    @disk_throughput_baseline_mbps = disk_throughput_baseline_mbps
    @service_cgroup = "/sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@#{instance}.service"
    @throttled_cgroup = "#{@service_cgroup}/throttled"
    @immune_cgroup = "#{@service_cgroup}/immune"
    @data_dir = "/dat/#{instance.split("-").first}/data"
  end

  # Main entry point for the systemd timer: reads the archival backlog
  # ,disk usage, and slot wait, calculates appropriate throttle, and applies it.
  def run
    backlog = Dir.glob("#{@data_dir}/pg_wal/archive_status/*.ready").length
    archival_throttle_mbps = calculate_archival_throttle(backlog)
    disk_usage_throttle_mbps = calculate_disk_usage_throttle
    slot_wait_throttle_mbps = calculate_slot_wait_throttle
    throttle_mbps = [archival_throttle_mbps, disk_usage_throttle_mbps, slot_wait_throttle_mbps].compact.min
    return unless apply(throttle_mbps)

    @logger.info("Archival backlog: #{backlog} files (#{archival_throttle_mbps || "none"}), " \
      "disk usage throttle: #{disk_usage_throttle_mbps || "none"}, " \
      "slot wait throttle: #{slot_wait_throttle_mbps || "none"}, " \
      "effective: #{throttle_mbps ? "#{throttle_mbps} MB/s" : "none"}")
  end

  def apply(throttle_mbps, data_mount_path = "/dat")
    fail "Service cgroup not found: #{@service_cgroup}" unless File.directory?(@service_cgroup)

    @dev_id = find_device_id(data_mount_path)

    if throttle_mbps.nil?
      remove_throttle
    else
      apply_throttle(throttle_mbps)
    end
  end

  def remove_throttle
    io_max_file = "#{@throttled_cgroup}/io.max"
    had_limit = File.read(io_max_file).match?(/wbps=\d/)
    File.write(io_max_file, "#{@dev_id} wbps=max")
    had_limit
  rescue Errno::ENOENT
    false
  end

  def apply_throttle(throttle_mbps)
    return false unless enable_io_controller
    changed = set_io_limit(throttle_mbps)
    classify_processes
    changed
  end

  def find_postmaster_pid
    output = r("systemctl", "show", "postgresql@#{@instance}.service", "--property=MainPID", "--value").strip
    pid = Integer(output, 10)
    fail "postgresql@#{@instance}.service is not running" if pid == 0
    pid
  end

  def find_immune_pids
    postmaster_pid = find_postmaster_pid
    children = File.read("/proc/#{postmaster_pid}/task/#{postmaster_pid}/children").split.map { Integer(_1, 10) }

    immune_pids = [postmaster_pid]
    children.each do |pid|
      cmdline = File.read("/proc/#{pid}/cmdline").tr("\0", " ")
      immune_pids << pid if immune_patterns.any? { |pattern| cmdline.include?(pattern) }
    rescue Errno::ENOENT
      # Process exited between enumeration and read
      nil
    end
    immune_pids
  end

  # Patterns matching the Postgres children throttling must leave alone, because
  # throttling them would slow the very work that relieves the pressure.
  def immune_patterns
    IMMUNE_PATTERNS
  end

  def get_cgroup_pids(cgroup_path)
    File.read("#{cgroup_path}/cgroup.procs").split.map { Integer(_1, 10) }
  rescue Errno::ENOENT
    []
  end

  def move_pid_to_cgroup(pid, cgroup_path)
    File.write("#{cgroup_path}/cgroup.procs", pid.to_s)
  rescue Errno::ESRCH
    # Process no longer exists
    nil
  end

  private

  def calculate_archival_throttle(backlog_count)
    IO_THROTTLE_RATIOS.each do |threshold, ratio|
      return (@disk_throughput_baseline_mbps * ratio).round if backlog_count >= threshold
    end
    nil
  end

  # descend to 1% of baseline, starting at 91% disk usage
  def calculate_disk_usage_throttle
    return nil if in_recovery?
    disk_usage_percent = Integer(r("df --output=pcent /dat | tail -n 1").strip.delete_suffix("%"), 10)
    return nil if disk_usage_percent < 91
    ratio = 1.0 - 0.11 * (disk_usage_percent - 91)
    (@disk_throughput_baseline_mbps * ratio).round
  end

  def calculate_slot_wait_throttle
    return nil if !Dir.exist?(SLOT_WAIT_DIR) || in_recovery?

    signals = Dir.glob(File.join(SLOT_WAIT_DIR, "*.wait_signal")).to_h { |path| [File.basename(path, ".wait_signal"), path] }
    return nil if signals.empty?

    ages = signals.transform_values { |path| Time.now - File.mtime(path) }
    expired, pending = signals.partition { |slot, _| ages[slot] > SLOT_WAIT_MAX_AGE }
    expired.each do |slot, path|
      @logger.warn("Slot #{slot} did not connect within #{SLOT_WAIT_MAX_AGE}s, no longer throttling for it")
      File.delete(path)
    end

    connected = connected_slots(pending.map(&:first))
    connected_signals, waiting = pending.partition { |slot, _| connected.include?(slot) }
    connected_signals.each do |slot, path|
      @logger.info("Slot #{slot} connected")
      File.delete(path)
    end

    (@disk_throughput_baseline_mbps * SLOT_WAIT_RATIO).round if waiting.any? { |slot, _| ages[slot] > SLOT_WAIT_GRACE }
  end

  def connected_slots(slots)
    return [] if slots.empty?
    names = slots.map { |slot| "'#{slot}'" }.join(",")
    r("sudo", "-u", "postgres", "psql", "-At", "-c", "SELECT slot_name FROM pg_catalog.pg_replication_slots WHERE active AND slot_name IN (#{names})").split("\n")
  end

  # Recovery throttles the startup process and walreceiver, which drive
  # replay, so a near-full disk fills faster instead of slower.
  def in_recovery?
    File.exist?("#{@data_dir}/standby.signal") || File.exist?("#{@data_dir}/recovery.signal")
  end

  def find_device_id(mount_path)
    data_disk = File.realpath(r("findmnt", "-n", "-o", "SOURCE", mount_path).strip)
    dev_stat = File.stat(data_disk)
    "#{dev_stat.rdev_major}:#{dev_stat.rdev_minor}"
  end

  def enable_io_controller
    subtree_control = "#{@service_cgroup}/cgroup.subtree_control"
    return true if File.read(subtree_control).include?("io")

    FileUtils.mkdir_p(@throttled_cgroup)
    FileUtils.mkdir_p(@immune_cgroup)

    get_cgroup_pids(@service_cgroup).each do |pid|
      move_pid_to_cgroup(pid, @throttled_cgroup)
    end

    File.write(subtree_control, "+io")
    true
  rescue Errno::ENOENT, Errno::EBUSY, Errno::EPERM, Errno::EACCES => e
    @logger.warn("Cannot enable I/O controller (#{e.class}): #{e.message} (at #{e.backtrace.first}). Ensure Delegate=yes is set on the systemd service.")
    false
  end

  def set_io_limit(throttle_mbps)
    io_max_file = "#{@throttled_cgroup}/io.max"
    throttle_bytes = throttle_mbps * 1024 * 1024
    changed = !File.read(io_max_file).match?(/wbps=#{throttle_bytes}\b/)
    File.write(io_max_file, "#{@dev_id} wbps=#{throttle_bytes}")
    changed
  end

  def classify_processes
    immune_pids = find_immune_pids

    immune_pids.each do |pid|
      move_pid_to_cgroup(pid, @immune_cgroup)
    end

    (get_cgroup_pids(@service_cgroup) + get_cgroup_pids(@immune_cgroup)).each do |pid|
      next if immune_pids.include?(pid)
      move_pid_to_cgroup(pid, @throttled_cgroup)
    end

    get_cgroup_pids(@throttled_cgroup).each do |pid|
      move_pid_to_cgroup(pid, @immune_cgroup) if immune_pids.include?(pid)
    end

    immune_pids
  end
end

require_relative "override/io_throttle"
