# frozen_string_literal: true

require "time"
require "json"
require_relative "../../common/lib/util"

class StatsCollection
  def initialize(vm_name, slice)
    @vm_name = vm_name
    @slice = slice
  end

  def cpu_stats
    path = File.join("/sys/fs/cgroup", @slice, @vm_name + ".service", "cpu.stat")
    stat = File.read(path)
    stat_hash = stat.split("\n").map { |line| line.split(" ") }.to_h
    {
      cpu_usage_usec: stat_hash["usage_usec"].to_i
    }
  end

  def memory_stats
    log_file = "/vm/#{@vm_name}/serial.log"

    File.foreach(log_file).reverse_each do |line|
      if line.include?("memory-stats:")
        parsed = JSON.parse(line.split("memory-stats:").last.strip)
        return {
          memory_total_kb: parsed["total"],
          memory_free_kb: parsed["free"]
        }
      end
    end

    {}
  end

  def network_stats
    api_socket = "/vm/#{@vm_name}/ch-api.sock"
    output = r "/opt/cloud-hypervisor/v35.1/ch-remote --api-socket #{api_socket} counters"

    begin
      data = JSON.parse(output)
    rescue JSON::ParserError
      raise "Failed to parse JSON output from command: #{output}"
    end

    rx_bytes_sum = 0
    tx_bytes_sum = 0

    data.each do |key, values|
      if key.start_with?("_net")
        rx_bytes_sum += values["rx_bytes"] || 0
        tx_bytes_sum += values["tx_bytes"] || 0
      end
    end

    {
      rx_bytes: rx_bytes_sum,
      tx_bytes: tx_bytes_sum
    }
  end

  def stats_path
    File.join("/vm/logs", "#{@vm_name}.log")
  end

  def collect_stats
    cpu_stats.merge(memory_stats).merge(network_stats)
  end

  def record_stats
    stats = collect_stats
    stats["timestamp"] = Time.now.utc.iso8601
    File.open(stats_path, "a") do |f|
      f.puts(stats.to_json)
    end
  end
end
