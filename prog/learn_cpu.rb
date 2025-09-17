# frozen_string_literal: true

class Prog::LearnCpu < Prog::Base
  subject_is :sshable
  CpuTopology = Struct.new(:total_cpus, :total_cores, :total_dies, :total_sockets, keyword_init: true)

  def get_arch
    arch = sshable.cmd("common/bin/arch").strip
    fail "BUG: unexpected CPU architecture" unless ["arm64", "x64"].include?(arch)

    arch
  end

  def get_topology
    s = sshable.cmd("/usr/bin/lscpu -Jye")
    parsed = JSON.parse(s).fetch("cpus").map { |cpu|
      [cpu.fetch("socket"), cpu.fetch("core")]
    }
    cpus = parsed.count
    sockets = parsed.map { |socket, _| socket }.uniq.count
    cores = parsed.uniq.count

    CpuTopology.new(total_cpus: cpus, total_cores: cores, total_dies: 0,
      total_sockets: sockets)
  end

  def count_dies(arch:, total_sockets:)
    # Linux kernel doesn't provide die_id information for arm64.
    return total_sockets if arch == "arm64"

    die_ids = sshable.cmd("cat /sys/devices/system/cpu/cpu*/topology/die_id").split("\n")
    die_ids.uniq.count
  end

  label def start
    arch = get_arch
    topo = get_topology
    topo.total_dies = count_dies(total_sockets: topo.total_sockets, arch: arch)
    pop(arch: arch, **topo.to_h)
  end
end
