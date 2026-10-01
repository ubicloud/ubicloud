# frozen_string_literal: true

# Existing GCP VMs carry memory_gib values derived from the wrong size tables:
#
# - GCE c4-standard and c4-highmem ship 3.75 and 7.75 GiB per vCPU, and
#   c4d-standard and c4d-highmem ship 3.875 and 7.875, but the tables used 4
#   and 8 until the mem_ratio fix, so every earlier c4 and c4d VM is
#   overstated (c4-standard-4: 16 instead of 15, c4-highmem-8: 64 instead of
#   62, c4d-standard-384: 1536 instead of 1488). Recompute from vcpus using
#   the same floored product as Option.
# - z3-highmem-176-standardlssd ships 1406 GiB, not the 1408 the z3 8x ratio
#   gives, which is now recorded in that family's memory_gib_overrides.
#
# Only rows still carrying the old value are touched, so VMs created after the
# fix are left alone and the migration is idempotent.
#
# Postgres work_mem, maintenance_work_mem, effective_cache_size and
# autovacuum_work_mem are derived from vm.memory_gib when a server is
# configured, so affected PostgresServers need incr_configure after this
# runs. All four are reloadable, so no restart is needed. shared_buffers is
# unaffected: configure-hugepages sizes it from MemTotal in /proc/meminfo on
# every start and writes it to conf.d/002-hugepages.conf, which overrides the
# value derived here.
Sequel.migration do
  ratios = {"c4-standard" => [4, 3.75], "c4-highmem" => [8, 7.75], "c4d-standard" => [4, 3.875], "c4d-highmem" => [8, 7.875]}
  # [family, vcpus, old memory_gib, new memory_gib]
  shapes = [["z3-standardlssd", 176, 1408, 1406]]

  up do
    ratios.each do |family, (old_ratio, new_ratio)|
      from(:vm)
        .where(family:, memory_gib: Sequel[:vcpus] * old_ratio)
        .update(memory_gib: Sequel.function(:floor, Sequel[:vcpus] * new_ratio).cast(:integer))
    end

    shapes.each do |family, vcpus, old_memory_gib, new_memory_gib|
      from(:vm).where(family:, vcpus:, memory_gib: old_memory_gib).update(memory_gib: new_memory_gib)
    end
  end

  down do
    ratios.each do |family, (old_ratio, new_ratio)|
      from(:vm)
        .where(family:, memory_gib: Sequel.function(:floor, Sequel[:vcpus] * new_ratio).cast(:integer))
        .update(memory_gib: Sequel[:vcpus] * old_ratio)
    end

    shapes.each do |family, vcpus, old_memory_gib, new_memory_gib|
      from(:vm).where(family:, vcpus:, memory_gib: new_memory_gib).update(memory_gib: old_memory_gib)
    end
  end
end
