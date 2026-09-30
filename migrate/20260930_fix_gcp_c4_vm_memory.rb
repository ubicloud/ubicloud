# frozen_string_literal: true

# GCE c4-standard and c4-highmem ship 3.75 and 7.75 GiB per vCPU, but the
# size tables advertised 4 and 8 until the mem_ratio fix, so every c4 VM
# created before it has memory_gib overstated (c4-standard-4: 16 instead of
# 15, c4-highmem-8: 64 instead of 62). Recompute from vcpus using the same
# floored product as Option::VmSizes. Only rows still carrying the old
# product are touched, so VMs created after the fix are left alone.
#
# Postgres tuning (shared_buffers etc.) is derived from vm.memory_gib when a
# server is configured, so affected PostgresServers need incr_configure (and
# a restart for shared_buffers) after this runs.
Sequel.migration do
  ratios = {"c4-standard" => [4, 3.75], "c4-highmem" => [8, 7.75]}

  up do
    ratios.each do |family, (old_ratio, new_ratio)|
      from(:vm)
        .where(family:, memory_gib: Sequel[:vcpus] * old_ratio)
        .update(memory_gib: Sequel.function(:floor, Sequel[:vcpus] * new_ratio).cast(:integer))
    end
  end

  down do
    ratios.each do |family, (old_ratio, new_ratio)|
      from(:vm)
        .where(family:, memory_gib: Sequel.function(:floor, Sequel[:vcpus] * new_ratio).cast(:integer))
        .update(memory_gib: Sequel[:vcpus] * old_ratio)
    end
  end
end
