# frozen_string_literal: true

require "json"

class Prog::LearnCores < Prog::Base
  subject_is :sshable

  CpuTopology = Struct.new(:total_cpus, :total_cores, :total_nodes, :total_sockets, keyword_init: true)

  def parse_count(s)
    parsed = JSON.parse(s).fetch("cpus").map { |cpu|
      [cpu.fetch("socket"), cpu.fetch("node"), cpu.fetch("core")]
    }
    cpus = parsed.count
    sockets = parsed.map { |socket, _, _| socket }.uniq.count
    nodes = parsed.map { |socket, node, _| [socket, node] }.uniq.count
    cores = parsed.uniq.count

    CpuTopology.new(total_cpus: cpus, total_cores: cores,
      total_nodes: nodes, total_sockets: sockets)
  end

  label def start
    topo = parse_count(sshable.cmd("/usr/bin/lscpu -Jye"))
    pop(**topo.to_h)
  end
end
