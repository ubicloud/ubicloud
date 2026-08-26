# frozen_string_literal: true

class Prog::LearnCpu < Prog::Base
  subject_is :sshable

  def get_arch
    arch = sshable.cmd("common/bin/arch").strip
    fail "BUG: unexpected CPU architecture" unless ["arm64", "x64"].include?(arch)

    arch
  end

  def get_topology
    cpus = sshable.cmd_json("/usr/bin/lscpu -Jye").fetch("cpus")
    parsed = cpus.map { it.fetch_values("socket", "core") }
    total_cpus = parsed.count
    sockets = parsed.map { |socket, _| socket }.uniq.count
    cores = parsed.uniq.count
    cpu_numa_nodes = cpus.sort_by! { |cpu| cpu.fetch("cpu").to_i }.map! { |cpu| cpu["node"]&.to_i }

    {total_cpus:, total_cores: cores, total_sockets: sockets, cpu_numa_nodes:}
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
    total_dies = count_dies(total_sockets: topo[:total_sockets], arch:)
    pop(arch:, **topo, total_dies:)
  end
end
