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
         "node": 0,
         "socket": 0,
         "core": 0,
         "l1d:l1i:l2:l3": "0:0:0:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.0060
      },{
         "cpu": 1,
         "node": 0,
         "socket": 0,
         "core": 0,
         "l1d:l1i:l2:l3": "1:1:1:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.1600
      },{
         "cpu": 2,
         "node": 1,
         "socket": 0,
         "core": 1,
         "l1d:l1i:l2:l3": "2:2:2:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.0340
      },{
         "cpu": 3,
         "node": 1,
         "socket": 0,
         "core": 1,
         "l1d:l1i:l2:l3": "3:3:3:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.1680
      },{
         "cpu": 4,
         "node": 2,
         "socket": 1,
         "core": 0,
         "l1d:l1i:l2:l3": "0:0:0:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.0060
      },{
         "cpu": 5,
         "node": 2,
         "socket": 1,
         "core": 0,
         "l1d:l1i:l2:l3": "1:1:1:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.1600
      },{
         "cpu": 6,
         "node": 3,
         "socket": 1,
         "core": 1,
         "l1d:l1i:l2:l3": "2:2:2:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.0340
      },{
         "cpu": 7,
         "node": 3,
         "socket": 1,
         "core": 1,
         "l1d:l1i:l2:l3": "3:3:3:0",
         "online": true,
         "maxmhz": 4500.0000,
         "minmhz": 800.0000,
         "mhz": 800.1680
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
      expect(lc).to receive(:sshable).and_return(sshable)
      expect(lc).to receive(:pop).with(total_sockets: 2, total_cores: 4, total_nodes: 4, total_cpus: 8)
      lc.start
    end
  end
end
