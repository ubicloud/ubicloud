# frozen_string_literal: true

require_relative "../../model/spec_helper"

# Concurrent slice allocations on the same host must pick disjoint cpusets
# instead of waiting on each other's vm_host_cpu row locks. This needs two
# real DB connections, so it opts out of the wrapping rollback-only
# transaction and cleans up its own committed rows.
RSpec.describe Scheduling::Allocator::VmHostSliceAllocation, :no_db_transaction do
  let(:vm_host) { create_vm_host(total_cpus: 12, total_cores: 6) }
  let(:allocation) { described_class.new(nil, Scheduling::Allocator::Request.new, nil) }

  before do
    @skip_leaked_thread_check = true
    (0..11).each do |cpu_number|
      VmHostCpu.create(vm_host_id: vm_host.id, cpu_number:, io: cpu_number < 2, numa_node: (cpu_number < 6) ? 0 : 1)
    end
  end

  after do
    DB[:vm_host_cpu].where(vm_host_id: vm_host.id).delete
    DB[:vm_host].where(id: vm_host.id).delete
    DB[:sshable].where(id: vm_host.id).delete
  end

  def with_locked_cpus(cpu_numbers)
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      DB.transaction do
        VmHostCpu.where(vm_host_id: vm_host.id, cpu_number: cpu_numbers).for_update.all
        ready.push(true)
        release.pop
      end
    end

    begin
      raise "holder never locked cpus" unless ready.pop(timeout: 10)

      DB.transaction(rollback: :always) do
        DB.run("SET LOCAL lock_timeout = '1s'")
        yield
      end
    ensure
      release.push(true)
      holder.join(5)
    end
  end

  it "skips cpus locked by a concurrent allocation" do
    with_locked_cpus(2..5) do
      expect(allocation.select_cpuset(vm_host.id, 4, threads_per_core: 2)).to eq([6, 7, 8, 9])
    end
  end

  it "moves to the next numa node when the preferred one is partly locked" do
    with_locked_cpus(2..3) do
      expect(allocation.select_cpuset(vm_host.id, 4, threads_per_core: 2)).to eq([6, 7, 8, 9])
    end
  end

  it "spans numa nodes using only unlocked cpus" do
    with_locked_cpus([6, 7]) do
      expect(allocation.select_cpuset(vm_host.id, 6, threads_per_core: 2)).to eq([2, 3, 4, 5, 8, 9])
    end
  end

  it "fails when concurrent allocations leave too few unlocked cpus" do
    with_locked_cpus(2..9) do
      expect { allocation.select_cpuset(vm_host.id, 4, threads_per_core: 2) }.to raise_error RuntimeError, "failed to allocate cpus"
    end
  end
end
