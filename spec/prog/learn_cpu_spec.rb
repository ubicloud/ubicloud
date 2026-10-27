# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnCpu do
  subject(:lc) { described_class.new(Strand.create_with_id(sshable, prog: "LearnCpu", label: "start")) }

  let(:sshable) { Sshable.create(host: "test") }

  # Gin up a topologically complex processor to test summations.
  let(:eight_thread_four_core_four_numa_two_socket) do
    <<JSON
{
   "cpus": [
      {
         "cpu": 0,
         "node": 0,
         "socket": 0,
         "core": 0
      },{
         "cpu": 1,
         "node": 0,
         "socket": 0,
         "core": 0
      },{
         "cpu": 2,
         "node": 1,
         "socket": 0,
         "core": 1
      },{
         "cpu": 3,
         "node": 1,
         "socket": 0,
         "core": 1
      },{
         "cpu": 4,
         "node": 2,
         "socket": 1,
         "core": 0
      },{
         "cpu": 5,
         "node": 2,
         "socket": 1,
         "core": 0
      },{
         "cpu": 6,
         "node": 3,
         "socket": 1,
         "core": 1
      },{
         "cpu": 7,
         "node": 3,
         "socket": 1,
         "core": 1
      }
   ]
}
JSON
  end

  # Ubuntu 22.04's older util-linux quotes every lscpu field, including
  # "cpu" and "node", as a JSON string, and lists cpus out of numeric
  # order across sockets/NUMA nodes.
  let(:twelve_thread_six_core_two_numa_two_socket_string_fields) do
    <<JSON
{
   "cpus": [
      {"cpu": "0", "node": "0", "socket": "0", "core": "0", "l1d:l1i:l2:l3": "0:0:0:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "1", "node": "0", "socket": "0", "core": "0", "l1d:l1i:l2:l3": "0:0:0:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "3100.000"},
      {"cpu": "2", "node": "0", "socket": "0", "core": "1", "l1d:l1i:l2:l3": "1:1:1:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "3", "node": "0", "socket": "0", "core": "1", "l1d:l1i:l2:l3": "1:1:1:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2900.000"},
      {"cpu": "10", "node": "1", "socket": "1", "core": "4", "l1d:l1i:l2:l3": "4:4:4:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "11", "node": "1", "socket": "1", "core": "4", "l1d:l1i:l2:l3": "4:4:4:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2700.000"},
      {"cpu": "4", "node": "1", "socket": "1", "core": "2", "l1d:l1i:l2:l3": "2:2:2:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "5", "node": "1", "socket": "1", "core": "2", "l1d:l1i:l2:l3": "2:2:2:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2600.000"},
      {"cpu": "6", "node": "0", "socket": "0", "core": "3", "l1d:l1i:l2:l3": "3:3:3:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "7", "node": "0", "socket": "0", "core": "3", "l1d:l1i:l2:l3": "3:3:3:0", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "3000.000"},
      {"cpu": "8", "node": "1", "socket": "1", "core": "5", "l1d:l1i:l2:l3": "5:5:5:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "800.000"},
      {"cpu": "9", "node": "1", "socket": "1", "core": "5", "l1d:l1i:l2:l3": "5:5:5:1", "online": "yes", "maxmhz": "3200.0000", "minmhz": "800.0000", "mhz": "2800.000"}
   ]
}
JSON
  end

  # Ubuntu 24.04's util-linux emits numeric lscpu fields as JSON numbers,
  # and includes extra columns LearnCpu doesn't use.
  let(:eight_thread_four_core_two_numa_two_socket_numeric_fields) do
    <<JSON
{
   "cpus": [
      {"cpu": 0, "node": 0, "socket": 0, "core": 0, "l1d:l1i:l2:l3": "0:0:0:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4312.5000},
      {"cpu": 1, "node": 0, "socket": 0, "core": 0, "l1d:l1i:l2:l3": "0:0:0:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 2, "node": 0, "socket": 0, "core": 1, "l1d:l1i:l2:l3": "1:1:1:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4801.2200},
      {"cpu": 3, "node": 0, "socket": 0, "core": 1, "l1d:l1i:l2:l3": "1:1:1:0", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 4, "node": 1, "socket": 1, "core": 2, "l1d:l1i:l2:l3": "2:2:2:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4600.3300},
      {"cpu": 5, "node": 1, "socket": 1, "core": 2, "l1d:l1i:l2:l3": "2:2:2:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000},
      {"cpu": 6, "node": 1, "socket": 1, "core": 3, "l1d:l1i:l2:l3": "3:3:3:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 4700.4400},
      {"cpu": 7, "node": 1, "socket": 1, "core": 3, "l1d:l1i:l2:l3": "3:3:3:1", "online": true, "maxmhz": 5300.0000, "minmhz": 400.0000, "mhz": 400.0000}
   ]
}
JSON
  end

  # Hosts without NUMA support at the kernel/sysfs level (no
  # /sys/devices/system/node) omit the "node" field entirely.
  let(:four_thread_two_core_no_numa) do
    <<JSON
{
   "cpus": [
      {"cpu": 0, "socket": 0, "core": 0},
      {"cpu": 1, "socket": 0, "core": 0},
      {"cpu": 2, "socket": 0, "core": 1},
      {"cpu": 3, "socket": 0, "core": 1}
   ]
}
JSON
  end

  describe "#get_arch" do
    it "returns the architecture" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      expect(lc.get_arch).to eq("x64")
    end

    it "fails when there's an unexpected architecture" do
      expect(lc.sshable).to receive(:_cmd).with("common/bin/arch").and_return("s390x")
      expect { lc.get_arch }.to raise_error RuntimeError, "BUG: unexpected CPU architecture"
    end
  end

  describe "#get_topology" do
    it "returns the CPU topology" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_four_numa_two_socket,
      )
      expect(lc.get_topology).to eq({total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3], cpu_cores: [0, 0, 1, 1, 2, 2, 3, 3]})
    end

    it "maps each cpu to its core when the hyperthreads of a core are not numbered next to each other" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(<<JSON)
{"cpus": [
  {"cpu": 0, "socket": 0, "core": 0},
  {"cpu": 1, "socket": 0, "core": 1},
  {"cpu": 2, "socket": 0, "core": 0},
  {"cpu": 3, "socket": 0, "core": 1}
]}
JSON
      expect(lc.get_topology).to eq({total_cpus: 4, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil, nil, nil, nil], cpu_cores: [0, 1, 0, 1]})
    end

    it "ignores extra lscpu columns and a boolean online field (Ubuntu 24.04-style output)" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_two_numa_two_socket_numeric_fields,
      )
      expect(lc.get_topology).to eq({total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 0, 0, 1, 1, 1, 1], cpu_cores: [0, 0, 1, 1, 2, 2, 3, 3]})
    end

    it "coerces string cpu/node fields to integers and sorts numerically, not lexicographically (Ubuntu 22.04-style output)" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        twelve_thread_six_core_two_numa_two_socket_string_fields,
      )
      expect(lc.get_topology).to eq(
        {total_cpus: 12, total_cores: 6, total_sockets: 2, cpu_numa_nodes: [0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1], cpu_cores: [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]},
      )
    end

    it "reports nil numa nodes when the host has no NUMA data at all" do
      expect(lc.sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(four_thread_two_core_no_numa)
      expect(lc.get_topology).to eq({total_cpus: 4, total_cores: 2, total_sockets: 1, cpu_numa_nodes: [nil, nil, nil, nil], cpu_cores: [0, 0, 1, 1]})
    end
  end

  describe "#count_dies" do
    it "returns the number of dies" do
      expect(lc.sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu*/topology/die_id").and_return("0\n1\n0\n1\n")
      expect(lc.count_dies(arch: "x64", total_sockets: 2)).to eq(2)
    end

    it "returns the number of sockets when on arm64" do
      expect(lc.count_dies(arch: "arm64", total_sockets: 2)).to eq(2)
    end
  end

  describe "#start" do
    def expect_cpu_commands(sshable)
      expect(sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      expect(sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(eight_thread_four_core_four_numa_two_socket)
      expect(sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu*/topology/die_id").and_return("0\n1\n0\n1\n")
    end

    it "pops with cpu info" do
      expect_cpu_commands(lc.sshable)
      expect { lc.start }.to exit("arch" => "x64", "total_cpus" => 8, "total_cores" => 4, "total_dies" => 2, "total_sockets" => 2, "cpu_numa_nodes" => [0, 0, 1, 1, 2, 2, 3, 3], "cpu_cores" => [0, 0, 1, 1, 2, 2, 3, 3])
    end

    it "returns string keys to a pushing prog, so it can read retval right away" do
      pushed = described_class.new(Strand.create_with_id(sshable, prog: "LearnCpu", label: "start", stack: [{"subject_id" => sshable.id, "link" => ["LearnCpuTopology", "start"]}, {}]))
      expect_cpu_commands(pushed.sshable)
      expect { pushed.start }.to hop("start", "LearnCpuTopology") { |hop|
        expect(hop.strand_update_args[:retval]).to eq("arch" => "x64", "total_cpus" => 8, "total_cores" => 4, "total_dies" => 2, "total_sockets" => 2, "cpu_numa_nodes" => [0, 0, 1, 1, 2, 2, 3, 3], "cpu_cores" => [0, 0, 1, 1, 2, 2, 3, 3])
      }
    end
  end
end
