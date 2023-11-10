# frozen_string_literal: true

require "json"

class Prog::LearnCores < Prog::Base
  subject_is :sshable

  CpuTopology = Struct.new(:total_cpus, :total_cores, :total_dies, :total_sockets, keyword_init: true)

  def parse_count(s, dies)
    parsed = JSON.parse(s).fetch("cpus").map { |cpu|
      [cpu.fetch("socket"), cpu.fetch("core")]
    }
    cpus = parsed.count
    sockets = parsed.map { |socket, _| socket }.uniq.count
    cores = parsed.uniq.count

    CpuTopology.new(total_cpus: cpus, total_cores: cores, total_dies: dies,
      total_sockets: sockets)
  end

  def count_dies
    Integer(sshable.cmd("cat /sys/devices/system/cpu/cpu*/topology/die_id | sort -n | uniq | wc -l"))
  end

  label def start
    topo = parse_count(sshable.cmd("/usr/bin/lscpu -Jye"), count_dies)
    pop(**topo.to_h)
  end
end
