# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      # N.B. this is an expedient, such a simple counter cannot handle
      # more complex NUMA topological allocations.  For example, on a
      # Ampere Altra, there are 20 processors per NUMA node and four
      # nodes in a socket.  Through a series of allocations and
      # deallocations, you will have a sub-optimal situation where you
      # cannot concentrate a guest workload on as few or as symmetric
      # NUMA nodes and accompanying memory as would otherwise be
      # possible.
      add_column :used_cores, Integer, null: false, default: 0

      # Do not allocate one core on each host. This currently presumed
      # to be enough to offset host memory overheads, though that
      # simplification will require improvements later.
      add_constraint(:core_allocation_limit) { used_cores < total_cores }

      # Catch over-deallocation bugs.
      add_constraint(:used_cores_above_zero) { used_cores >= 0 }
    end
  end
end
