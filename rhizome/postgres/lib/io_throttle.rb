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
  # and disk usage, calculates appropriate throttle, and applies it.
  def run
    backlog = Dir.glob("#{@data_dir}/pg_wal/archive_status/*.ready").length
    archival_throttle_mbps = calculate_archival_throttle(backlog)
    disk_usage_throttle_mbps = calculate_disk_usage_throttle
    throttle_mbps = [archival_throttle_mbps, disk_usage_throttle_mbps].compact.min
    @logger.info("Archival backlog: #{backlog} files (#{archival_throttle_mbps || "none"}), " \
      "disk usage throttle: #{disk_usage_throttle_mbps || "none"}, " \
      "effective: #{throttle_mbps ? "#{throttle_mbps} MB/s" : "none"}")
    apply(throttle_mbps)
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
    File.write(io_max_file, "#{@dev_id} wbps=max")
    @logger.info("Removed I/O throttle")
  rescue Errno::ENOENT
    @logger.info("No throttle to remove")
  end

  def apply_throttle(throttle_mbps)
    return unless enable_io_controller
    set_io_limit(throttle_mbps)
    immune_pids = classify_processes
    @logger.info("Applied I/O throttle: #{throttle_mbps} MB/s (immune pids: #{immune_pids.join(", ")})")
  end

  def find_postmaster_pid
    output = r("systemctl show postgresql@#{@instance}.service --property=MainPID --value").strip
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
      immune_pids << pid if IMMUNE_PATTERNS.any? { |pattern| cmdline.include?(pattern) }
    rescue Errno::ENOENT
      # Process exited between enumeration and read
    end
    immune_pids
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
  end

  private

  def calculate_archival_throttle(backlog_count)
    IO_THROTTLE_RATIOS.each do |threshold, ratio|
      return (@disk_throughput_baseline_mbps * ratio).round if backlog_count >= threshold
    end
    nil
  end

  # descend to 25% of baseline, starting at 95% disk usage
  def calculate_disk_usage_throttle
    disk_usage_percent = Integer(r("df --output=pcent /dat | tail -n 1").strip.delete_suffix("%"), 10)
    return nil if disk_usage_percent < 95
    ratio = 1.0 - 0.15 * (disk_usage_percent - 95)
    (@disk_throughput_baseline_mbps * ratio).round
  end

  def find_device_id(mount_path)
    data_disk = File.realpath(r("findmnt -n -o SOURCE #{mount_path}").strip)
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
    throttle_bytes = throttle_mbps * 1024 * 1024
    File.write("#{@throttled_cgroup}/io.max", "#{@dev_id} wbps=#{throttle_bytes}")
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
