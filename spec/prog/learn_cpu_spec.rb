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
      expect(lc.get_topology).to eq({total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3]})
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
    it "pops with cpu info" do
      allow(lc).to receive_messages(
        get_arch: "x64",
        get_topology: {total_cpus: 8, total_cores: 4, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3]},
        count_dies: 2,
      )
      expect { lc.start }.to exit(arch: "x64", total_cpus: 8, total_cores: 4, total_dies: 2, total_sockets: 2, cpu_numa_nodes: [0, 0, 1, 1, 2, 2, 3, 3])
    end
  end
end
