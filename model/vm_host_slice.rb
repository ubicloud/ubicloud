# frozen_string_literal: true

require "bitarray"
require_relative "../model"

class VmHostSlice < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host

  include ResourceMethods
  include SemaphoreMethods
  # TODO: include HealthMonitorMethods
  semaphore :destroy, :start_after_host_reboot

  # Converts AllowedCPUs format to a bitmask
  # We use cgroup format for storying AllowedCPUs list,
  # which looks like this:
  # 2-3,6-10
  # (comma-separated ranges of cpus)
  #
  # Returns an array of size of #cpus at the host
  # with 1s in slots for allowed cpus and 0s elsewhere
  def self.cpuset_to_bitmask(cpuset)
    fail "Cpuset cannot be empty." if cpuset.nil? || cpuset.empty?
    fail "Cpuset can only contains numbers, comma (,) , and hypen (-)." unless /^[[0-9]+-?*,?]+$/.match?(cpuset)

    cpu_groups = cpuset.split(",").map { _1.strip }
    cpu_ranges = cpu_groups.map { _1.split("-").map { |n| n.to_i } }
    # expand each range if it is just one value
    cpu_ranges.each do |range|
      if range.size == 1
        range.append(range[0])
      elsif range.size != 2
        fail "Unexpected list of cpus in the cpuset."
      end
    end

    # we now have a set of ranges, each cpu range
    # describing a low and high end
    # it is possible to low and high end to be the same
    fail "Invalid list of cpus in the cpuset." unless cpu_ranges.reduce(false) { |acc, n| n[0] <= n[1] }

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
    bitmask = VmHostSlice.cpuset_to_bitmask(allowed_cpus)

    # if we know the number of cpus on the host,
    # resize the bitarray to that size
    if !vm_host.nil? && bitmask.size < vm_host.total_cpus
      expanded_bitmask = BitArray.new(vm_host.total_cpus)

      # TODO: there might be a better way to do it
      (0..bitmask.size).each { |i| expanded_bitmask[i] = bitmask[i] }
      bitmask = expanded_bitmask
    end

    bitmask
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
        idx_e = i - 1

        cpu_ranges.append((idx_b < idx_e) ? "#{idx_b}-#{idx_e}" : idx_b.to_s)
        idx_b = -1
        idx_e = -1
      end
    end

    # return a single list
    cpu_ranges.join(",")
  end

  def from_cpu_bitmask(bitmask)
    cpuset = VmHostSlice.bitmask_to_cpuset(bitmask)
    cpus = bitmask.reduce(&:+)
    fail "Bitmask does not set any cpuset." if cpus == 0 || cpuset.empty?

    # Get the proportion of cores to cpus from the host
    # TODO: We may need some more validation here
    threads_per_core = vm_host.total_cpus / vm_host.total_cores

    update(allowed_cpus: cpuset, cores: cpus / threads_per_core, total_cpu_percent: cpus * 100)
  end

  # Returns the name as used by systemctl and cgroup
  def inhost_name
    name + ".slice"
  end
end

# Table: vm_host_slice
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  enabled           | boolean                  | NOT NULL DEFAULT false
#  type              | vm_host_slice_type       | NOT NULL DEFAULT 'dedicated'::vm_host_slice_type
#  allowed_cpus      | text                     | NOT NULL
#  cores             | integer                  | NOT NULL
#  total_cpu_percent | integer                  | NOT NULL
#  used_cpu_percent  | integer                  | NOT NULL
#  total_memory_1g   | integer                  | NOT NULL
#  used_memory_1g    | integer                  | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  vm_host_id        | uuid                     |
# Indexes:
#  vm_host_slice_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  cores_not_negative       | (cores >= 0)
#  cpu_allocation_limit     | (used_cpu_percent <= total_cpu_percent)
#  memory_allocation_limit  | (used_memory_1g <= total_memory_1g)
#  used_cpu_not_negative    | (used_cpu_percent >= 0)
#  used_memory_not_negative | (used_memory_1g >= 0)
# Foreign key constraints:
#  vm_host_slice_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
