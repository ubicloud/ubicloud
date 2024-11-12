# frozen_string_literal: true

require "bitarray"
require_relative "../model"

class ResourceGroup < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host

  include ResourceMethods
  include SemaphoreMethods
  # TODO: include HealthMonitorMethods
  semaphore :destroy

  # Converts AllowedCPUs format to a bitmask
  # We use cgroup format for storying AllowedCPUs list,
  # which looks like this:
  # 2-3,6-10
  # (comma-separated ranges of cpus)
  #
  # Returns an array of size of #cpus at the host
  # with 1s in slots for allowed cpus and 0s elsewhere
  def self.cpuset_to_bitmask(cpuset)
    fail "cpuset cannot be empty" if cpuset.nil? || cpuset.empty?

    cpu_groups = cpuset.split(",").map { _1.strip }
    cpu_ranges = cpu_groups.map { _1.split("-").map { |n| n.to_i } }
    fail "undefined cpuset" if cpu_ranges.size == 0
    # expand each range if it is just one value
    cpu_ranges.each do |range|
      if range.size == 1
        range.append(range[0])
      elsif range.size != 2
        fail "unexpected range size"
      end
    end

    # we now have a set of ranges, each cpu range
    # describing a low and high end
    # it is possible to low and high end to be the same
    fail "invalid cpuset ranges" unless cpu_ranges.reduce(false) { |acc, n| n.size == 2 && n[0] <= n[1] }

    # we can convert to bitmask
    #
    # take the size of the bitmask to be just use the maximum of the range
    bitmask_size = cpu_ranges.reduce(0) { |acc, n| (acc < n[1]) ? n[1] : acc } + 1

    bitmask = BitArray.new(bitmask_size)
    cpu_ranges.each do |range|
      (range[0]..range[1]).to_a.each { |i| bitmask[i] = 1 }
    end

    bitmask
  end

  def to_cpu_bitmask
    ResourceGroup.cpuset_to_bitmask(allowed_cpus)

    # if we know the number of cpus on the host,
    # resize the bitarray to that size
    # unless vm_host.nil? && bitmask.size < vm_host.total_cpus
    #   expanded_bitmask = BitArray.new(vm_host.total_cpus)

    #   # TODO: there might be a better way to do it
    #   (0..bitmask.size).each { |i| expanded_bitmask[i] = bitmask[i] }
    #   bitmask = expanded_bitmask
    # end
  end

  # converts the bitmask array returned by the
  # above method back to the cgroup format
  def self.bitmask_to_cpuset(bitmask)
    cpu_ranges = []

    idx_b = -1
    idx_e = -1

    # specifically iterate until bitmask.size, to ensure we close the last range
    (0..bitmask.size).each do |i|
      if idx_b == -1 && idx_e == -1 && bitmask[i] == 1
        # first positive bit set
        idx_b = i
      end

      if idx_b != -1 && idx_e == -1 && bitmask[i] == 0
        # first negative bit set, after some poisitve ones
        idx_e = i

        cpu_ranges.append([idx_b, idx_e - 1])
        idx_b = -1
        idx_e = -1
      end
    end

    # convert the ranges into a string representation
    cpu_groups = cpu_ranges.map { |r| (r[0] < r[1]) ? "#{r[0]}-#{r[1]}" : "#{r[0]}" }
    cpu_groups.join(",")
  end

  def from_cpu_bitmask(bitmask)
    cpuset = ResourceGroup.bitmask_to_cpuset(bitmask)

    update(allowed_cpus: cpuset)
  end

  # Returns the name as used by systemctl and cgroup
  def inhost_name
    name + ".slice"
  end
end
