# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnCpu do
  subject(:lc) { described_class.new(Strand.new) }

  # Gin up a topologically complex processor to test summations.
  let(:eight_thread_four_core_four_numa_two_socket) do
    <<JSON
{
   "cpus": [
      {
         "cpu": 0,
         "socket": 0,
         "core": 0
      },{
         "cpu": 1,
         "socket": 0,
         "core": 0
      },{
         "cpu": 2,
         "socket": 0,
         "core": 1
      },{
         "cpu": 3,
         "socket": 0,
         "core": 1
      },{
         "cpu": 4,
         "socket": 1,
         "core": 0
      },{
         "cpu": 5,
         "socket": 1,
         "core": 0
      },{
         "cpu": 6,
         "socket": 1,
         "core": 1
      },{
         "cpu": 7,
         "socket": 1,
         "core": 1
      }
   ]
}
JSON
  end

  describe "#get_arch" do
    it "returns the architecture" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("common/bin/arch").and_return("x64")
      allow(lc).to receive(:sshable).and_return(sshable)
      expect(lc.get_arch).to eq("x64")
    end

    it "fails when there's an unexpected architecture" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("common/bin/arch").and_return("s390x")
      allow(lc).to receive(:sshable).and_return(sshable)
      expect { lc.get_arch }.to raise_error RuntimeError, "BUG: unexpected CPU architecture"
    end
  end

  describe "#get_topology" do
    it "returns the CPU topology" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_four_numa_two_socket
      )
      allow(lc).to receive(:sshable).and_return(sshable)
      expect(lc.get_topology).to eq(Prog::LearnCpu::CpuTopology.new(total_cpus: 8, total_cores: 4, total_dies: 0, total_sockets: 2))
    end
  end

  describe "#count_dies" do
    it "returns the number of dies" do
      sshable = Sshable.new
      expect(sshable).to receive(:_cmd).with("cat /sys/devices/system/cpu/cpu*/topology/die_id").and_return("0\n1\n0\n1\n")
      allow(lc).to receive(:sshable).and_return(sshable)
      expect(lc.count_dies(arch: "x64", total_sockets: 2)).to eq(2)
    end

    it "returns the number of sockets when on arm64" do
      sshable = Sshable.new
      allow(lc).to receive(:sshable).and_return(sshable)
      expect(lc.count_dies(arch: "arm64", total_sockets: 2)).to eq(2)
    end
  end

  describe "#start" do
    it "pops with cpu info" do
      allow(lc).to receive_messages(
        get_arch: "x64",
        get_topology: Prog::LearnCpu::CpuTopology.new(total_cpus: 8, total_cores: 4, total_dies: 0, total_sockets: 2),
        count_dies: 2
      )
      expect { lc.start }.to exit(arch: "x64", total_cpus: 8, total_cores: 4, total_dies: 2, total_sockets: 2)
    end
  end
end
