# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnCores do
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

  describe "#start" do
    it "exits, saving the number of cores" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("/usr/bin/lscpu -Jye").and_return(
        eight_thread_four_core_four_numa_two_socket
      )

      expect(sshable).to receive(:cmd).with(
        "cat /sys/devices/system/cpu/cpu*/topology/die_id | sort -n | uniq | wc -l"
      ).and_return("4")

      expect(lc).to receive(:sshable).and_return(sshable).twice
      expect { lc.start }.to exit({total_sockets: 2, total_cores: 4, total_dies: 4, total_cpus: 8})
    end
  end
end
