# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      # Previously, we didn't allocate one core on each host to offset host
      # memory overheads. Given that we will use 1 core (=2 vcpus) per host for
      # SPDK using only 1G, we can relax this constraint.
      drop_constraint :core_allocation_limit
      add_constraint(:core_allocation_limit) { used_cores <= total_cores }
    end

    # We had missed to account for SPDK in previous hosts. SPDK uses 1 vcpu in
    # all previous setups, which is one core.
    run <<~SQL
      UPDATE vm_host SET used_cores = used_cores + 1;
    SQL
  end
end
