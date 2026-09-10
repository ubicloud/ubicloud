# frozen_string_literal: true

require "json"
require "socket"
require_relative "vm_path"
require_relative "storage_path"
require_relative "vhost_block_backend"
require_relative "../../common/lib/util"

class VmStats
  def initialize(vm_name)
    @vm_name = vm_name
  end

  def collect
    result = {
      "vm" => unit_stats(
        @vm_name,
        with_io: false,    # Actual IO is done by the vhost block backend of each disk
        with_memory: false, # VM uses hugepages, so memory usage is not reflected in the process RSS
      ),
    }
    result["vm"]["vcpus"] = vm_params.fetch("max_vcpus")

    ubiblk_disks.each do |disk|
      disk_index = disk["disk_index"]
      result["disk_#{disk_index}"] = disk.except("disk_index", "storage_device").merge!(unit_stats(
        "#{@vm_name}-#{disk_index}-storage",
        with_io: true,
        with_memory: true,
      )).merge!(ubiblk_stats(disk))
    end

    result
  end

  def ubiblk_stats(disk)
    return {} unless VhostBlockBackend.new(disk.fetch("vhost_block_backend_version")).supports_stats_rpc?

    socket_path = StoragePath.new(@vm_name, disk["storage_device"] || DEFAULT_STORAGE_DEVICE, disk.fetch("disk_index")).rpc_socket_path
    queues = query_ubiblk_rpc(socket_path, {command: "stats"}).fetch("stats").fetch("queues")
    {
      "ubiblk_stats" => {
        "bytes_read" => queues.sum { |q| q.fetch("bytes_read") },
        "bytes_written" => queues.sum { |q| q.fetch("bytes_written") },
        "read_ops" => queues.sum { |q| q.fetch("read_ops") },
        "write_ops" => queues.sum { |q| q.fetch("write_ops") },
        "flush_ops" => queues.sum { |q| q.fetch("flush_ops") },
      },
    }
  rescue SystemCallError, IOError, JSON::ParserError => e
    {"ubiblk_stats_error" => "#{e.class}: #{e.message}"}
  end

  def query_ubiblk_rpc(socket_path, request)
    UNIXSocket.open(socket_path) do |socket|
      socket.puts(JSON.generate(request))
      JSON.parse(socket.readline)
    end
  end

  def unit_property(unit, name)
    output = (r "systemctl", "show", unit, "--property", name).strip
    raise "unexpected output from systemctl show: \"#{output}\"" unless output.delete_prefix!("#{name}=")
    output
  end

  def io_stats(main_pid)
    stats = {}
    File.foreach("/proc/#{main_pid}/io") do |line|
      key, value = line.split(": ", 2)
      case key
      when "read_bytes", "write_bytes"
        stats[key] = Integer(value, 10)
      end
    end
    stats
  end

  def cpu_stats(main_pid)
    stat_contents = File.read("/proc/#{main_pid}/stat")

    # skip pid and comm fields. comm can contain spaces, but is always wrapped
    # in parentheses.
    stat = stat_contents.rpartition(")").last.split

    user_time_ms = (Integer(stat[11], 10) * 1000) / clk_tick
    system_time_ms = (Integer(stat[12], 10) * 1000) / clk_tick
    total_time_ms = user_time_ms + system_time_ms
    {
      "user_time_ms" => user_time_ms,
      "system_time_ms" => system_time_ms,
      "total_time_ms" => total_time_ms,
    }
  end

  def unit_stats(unit_name, with_io: false, with_memory: false)
    main_pid = unit_property(unit_name, "MainPID")
    h = {
      "main_pid" => main_pid,
      "cpu_stats" => cpu_stats(main_pid),
      "active_age_ms" => unit_active_age_ms(unit_name),
    }
    if with_memory
      h["memory_peak_bytes"] = Integer(unit_property(unit_name, "MemoryPeak"), 10)
      h["memory_swap_peak_bytes"] = Integer(unit_property(unit_name, "MemorySwapPeak"), 10)
    end

    h["io_stats"] = io_stats(main_pid) if with_io
    h
  end

  def unit_active_age_ms(unit)
    enter_ts_monotonic = unit_property(unit, "ActiveEnterTimestampMonotonic")
    # It will return "0" if the unit is not active, in which case we want to
    # return nil rather than a large age
    return nil if enter_ts_monotonic.empty? || enter_ts_monotonic == "0"

    start_ms = Integer(enter_ts_monotonic, 10) / 1000
    uptime_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i

    uptime_ms - start_ms
  end

  def clk_tick
    @clk_tick ||= Integer(r("getconf", "CLK_TCK"), 10)
  end

  def vm_params
    @vm_params ||= begin
      vm_path = VmPath.new(@vm_name)
      JSON.parse(File.read(vm_path.prep_json))
    end
  end

  def ubiblk_disks
    @ubiblk_disks ||= vm_params.fetch("storage_volumes").filter_map do |sv|
      next unless sv["vhost_block_backend_version"]
      sv.slice("disk_index", "storage_device", "vhost_block_backend_version", "num_queues", "queue_size", "size_gib")
    end
  end
end
