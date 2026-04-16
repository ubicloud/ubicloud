# frozen_string_literal: true

require "logger"
require_relative "../lib/io_throttle"

RSpec.describe IoThrottle do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:throttle) { described_class.new("17-main", logger, 100) }
  let(:service_cgroup) { "/sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@17-main.service" }
  let(:throttled_cgroup) { "#{service_cgroup}/throttled" }
  let(:immune_cgroup) { "#{service_cgroup}/immune" }

  describe "#find_postmaster_pid" do
    it "reads PID from systemctl" do
      expect(throttle).to receive(:r).with("systemctl show postgresql@17-main.service --property=MainPID --value").and_return("5913\n")
      expect(throttle.find_postmaster_pid).to eq(5913)
    end

    it "fails if service is not running" do
      expect(throttle).to receive(:r).with("systemctl show postgresql@17-main.service --property=MainPID --value").and_return("0\n")
      expect { throttle.find_postmaster_pid }.to raise_error(/is not running/)
    end
  end

  describe "#find_immune_pids" do
    it "identifies immune processes by cmdline patterns" do
      expect(throttle).to receive(:find_postmaster_pid).and_return(1000)
      expect(File).to receive(:read).with("/proc/1000/task/1000/children")
        .and_return("1001 1002 1003 1004 1005")

      expect(File).to receive(:read).with("/proc/1001/cmdline").and_return("postgres: 17/main: logger")
      expect(File).to receive(:read).with("/proc/1002/cmdline").and_return("postgres: 17/main: checkpointer")
      expect(File).to receive(:read).with("/proc/1003/cmdline").and_return("postgres: 17/main: background writer")
      expect(File).to receive(:read).with("/proc/1004/cmdline").and_return("postgres: 17/main: archiver")
      expect(File).to receive(:read).with("/proc/1005/cmdline").and_return("postgres: 17/main: autovacuum launcher")

      immune_pids = throttle.find_immune_pids

      expect(immune_pids).to include(1000, 1001, 1002, 1003, 1004)
      expect(immune_pids).not_to include(1005)
    end

    it "includes walwriter via the 'writer' pattern" do
      expect(throttle).to receive(:find_postmaster_pid).and_return(100)
      expect(File).to receive(:read).with("/proc/100/task/100/children").and_return("101")
      expect(File).to receive(:read).with("/proc/101/cmdline").and_return("postgres: 17/main: walwriter")

      expect(throttle.find_immune_pids).to include(101)
    end

    it "skips processes that have exited between enumeration and read" do
      expect(throttle).to receive(:find_postmaster_pid).and_return(100)
      expect(File).to receive(:read).with("/proc/100/task/100/children").and_return("101 102")
      expect(File).to receive(:read).with("/proc/101/cmdline").and_raise(Errno::ENOENT)
      expect(File).to receive(:read).with("/proc/102/cmdline").and_return("postgres: 17/main: checkpointer")

      result = nil
      expect { result = throttle.find_immune_pids }.not_to raise_error
      expect(result).to include(100)
    end
  end

  describe "#get_cgroup_pids" do
    it "returns empty array if cgroup doesn't exist" do
      expect(File).to receive(:read).with("#{service_cgroup}/cgroup.procs").and_raise(Errno::ENOENT)
      expect(throttle.get_cgroup_pids(service_cgroup)).to eq([])
    end

    it "parses PIDs from cgroup.procs" do
      expect(File).to receive(:read).with("#{service_cgroup}/cgroup.procs").and_return("1000\n1001\n1002\n")
      expect(throttle.get_cgroup_pids(service_cgroup)).to eq([1000, 1001, 1002])
    end
  end

  describe "#move_pid_to_cgroup" do
    it "writes PID to cgroup.procs" do
      expect(File).to receive(:write).with("#{throttled_cgroup}/cgroup.procs", "1234")
      throttle.move_pid_to_cgroup(1234, throttled_cgroup)
    end

    it "ignores ESRCH for dead processes" do
      expect(File).to receive(:write).and_raise(Errno::ESRCH)
      expect { throttle.move_pid_to_cgroup(1234, throttled_cgroup) }.not_to raise_error
    end
  end

  describe "#remove_throttle" do
    before { throttle.instance_variable_set(:@dev_id, "8:0") }

    it "resets io.max to max" do
      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=max")
      throttle.remove_throttle
    end

    it "does nothing if throttled cgroup doesn't exist" do
      expect(File).to receive(:write).and_raise(Errno::ENOENT)
      expect { throttle.remove_throttle }.not_to raise_error
    end
  end

  describe "#apply" do
    before do
      allow(File).to receive(:directory?).with(service_cgroup).and_return(true)
      allow(throttle).to receive(:find_device_id).and_return("8:0")
    end

    it "removes throttle when throttle_mbps is nil" do
      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=max")
      throttle.apply(nil)
    end

    it "fails if service cgroup doesn't exist" do
      allow(File).to receive(:directory?).with(service_cgroup).and_return(false)
      expect { throttle.apply(100) }.to raise_error(/Service cgroup not found/)
    end
  end

  describe "#apply_throttle" do
    before do
      allow(File).to receive_messages(directory?: true, read: "")
      allow(File).to receive(:write)
      allow(Dir).to receive(:mkdir)
      throttle.instance_variable_set(:@dev_id, "8:0")
    end

    it "sets io.max with correct wbps value" do
      allow(throttle).to receive_messages(find_immune_pids: [1000], get_cgroup_pids: [])

      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=104857600")

      throttle.apply_throttle(100)
    end
  end

  describe "#calculate_disk_usage_throttle" do
    it "returns nil when disk usage is below 95%" do
      expect(throttle).to receive(:r).with("df --output=pcent /dat | tail -n 1").and_return("  94%\n")
      expect(throttle.send(:calculate_disk_usage_throttle)).to be_nil
    end

    it "returns baseline at 95% disk" do
      expect(throttle).to receive(:r).with("df --output=pcent /dat | tail -n 1").and_return("  95%\n")
      # ratio = 1.0 - 0.15 * 0 = 1.0 -> 100
      expect(throttle.send(:calculate_disk_usage_throttle)).to eq(100)
    end

    it "returns 70 MB/s at 97% disk" do
      expect(throttle).to receive(:r).with("df --output=pcent /dat | tail -n 1").and_return("  97%\n")
      # ratio = 1.0 - 0.15 * 2 = 0.70 -> 70
      expect(throttle.send(:calculate_disk_usage_throttle)).to eq(70)
    end

    it "descends to 25% of baseline at 100% disk" do
      expect(throttle).to receive(:r).with("df --output=pcent /dat | tail -n 1").and_return(" 100%\n")
      # ratio = 1.0 - 0.15 * 5 = 0.25 -> 25
      expect(throttle.send(:calculate_disk_usage_throttle)).to eq(25)
    end

    it "scales with disk throughput baseline" do
      throttle_aws = described_class.new("17-main", logger, 448)
      expect(throttle_aws).to receive(:r).with("df --output=pcent /dat | tail -n 1").and_return("  97%\n")
      # ratio = 0.70 -> 448 * 0.70 = 313.6 -> 314
      expect(throttle_aws.send(:calculate_disk_usage_throttle)).to eq(314)
    end
  end

  describe "#run" do
    let(:data_dir) { "/dat/17/data" }

    before do
      allow(File).to receive(:directory?).with(service_cgroup).and_return(true)
      allow(throttle).to receive_messages(find_device_id: "8:0", calculate_disk_usage_throttle: nil)
    end

    it "applies no throttle when backlog is below threshold and no disk usage throttle" do
      allow(Dir).to receive(:glob).with("#{data_dir}/pg_wal/archive_status/*.ready").and_return([])
      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=max")

      throttle.run
    end

    it "applies throttle tier based on backlog count" do
      ready_files = Array.new(150) { |i| "#{data_dir}/pg_wal/archive_status/#{i.to_s.rjust(8, "0")}.ready" }
      allow(Dir).to receive(:glob).with("#{data_dir}/pg_wal/archive_status/*.ready").and_return(ready_files)
      allow(File).to receive(:read).with("#{service_cgroup}/cgroup.subtree_control").and_return("io")
      allow(throttle).to receive_messages(find_immune_pids: [], get_cgroup_pids: [])

      # 150 files hits moderate tier (100+): 80% of baseline 100 MB/s = 80 MB/s
      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=#{80 * 1024 * 1024}")

      throttle.run
    end

    it "scales throttle values with the disk throughput baseline" do
      throttle_leaseweb = described_class.new("17-main", logger, 35)
      allow(File).to receive(:directory?).with(service_cgroup).and_return(true)
      allow(throttle_leaseweb).to receive_messages(find_device_id: "8:0", calculate_disk_usage_throttle: nil)

      ready_files = Array.new(150) { |i| "#{data_dir}/pg_wal/archive_status/#{i.to_s.rjust(8, "0")}.ready" }
      allow(Dir).to receive(:glob).with("#{data_dir}/pg_wal/archive_status/*.ready").and_return(ready_files)
      allow(File).to receive(:read).with("#{service_cgroup}/cgroup.subtree_control").and_return("io")
      allow(throttle_leaseweb).to receive_messages(find_immune_pids: [], get_cgroup_pids: [])

      # 150 files hits moderate tier (100+): 80% of baseline 35 MB/s = 28 MB/s
      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=#{28 * 1024 * 1024}")

      throttle_leaseweb.run
    end

    it "applies disk usage throttle when disk is high and no archival backlog" do
      expect(Dir).to receive(:glob).with("#{data_dir}/pg_wal/archive_status/*.ready").and_return([])
      expect(throttle).to receive(:calculate_disk_usage_throttle).and_return(55)
      expect(File).to receive(:read).with("#{service_cgroup}/cgroup.subtree_control").and_return("io")
      expect(throttle).to receive(:find_immune_pids).and_return([])
      expect(throttle).to receive(:get_cgroup_pids).and_return([]).at_least(:once)

      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=#{55 * 1024 * 1024}")

      throttle.run
    end

    it "uses more restrictive throttle when both apply" do
      ready_files = Array.new(150) { |i| "#{data_dir}/pg_wal/archive_status/#{i.to_s.rjust(8, "0")}.ready" }
      expect(Dir).to receive(:glob).with("#{data_dir}/pg_wal/archive_status/*.ready").and_return(ready_files)
      # Archival: 80 MB/s, disk usage: 55 MB/s -> pick 55
      expect(throttle).to receive(:calculate_disk_usage_throttle).and_return(55)
      expect(File).to receive(:read).with("#{service_cgroup}/cgroup.subtree_control").and_return("io")
      expect(throttle).to receive(:find_immune_pids).and_return([])
      expect(throttle).to receive(:get_cgroup_pids).and_return([]).at_least(:once)

      expect(File).to receive(:write).with("#{throttled_cgroup}/io.max", "8:0 wbps=#{55 * 1024 * 1024}")

      throttle.run
    end
  end
end
