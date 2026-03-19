# frozen_string_literal: true

require "json"
require_relative "vm_path"
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
        with_memory: false # VM uses hugepages, so memory usage is not reflected in the process RSS
      )
    }
    ubiblk_disks.each do |disk_index|
      result["disk_#{disk_index}"] =
        unit_stats("#{@vm_name}-#{disk_index}-storage", with_io: true, with_memory: true)
    end

    result
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
      "total_time_ms" => total_time_ms
    }
  end

  def unit_stats(unit_name, with_io: false, with_memory: false)
    main_pid = unit_property(unit_name, "MainPID")
    h = {
      "main_pid" => main_pid,
      "cpu_stats" => cpu_stats(main_pid)
    }
    if with_memory
      h["memory_peak_bytes"] = Integer(unit_property(unit_name, "MemoryPeak"), 10)
      h["memory_swap_peak_bytes"] = Integer(unit_property(unit_name, "MemorySwapPeak"), 10)
    end

    h["io_stats"] = io_stats(main_pid) if with_io
    h
  end

  def clk_tick
    @clk_tick ||= Integer(r("getconf", "CLK_TCK"), 10)
  end

  def ubiblk_disks
    @ubiblk_disks ||= begin
      vm_path = VmPath.new(@vm_name)
      params = JSON.parse(File.read(vm_path.prep_json))

      params.fetch("storage_volumes").filter_map do |sv|
        sv["disk_index"] if sv["vhost_block_backend_version"]
      end
    end
  end
end
