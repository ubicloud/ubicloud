# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      drop_constraint :core_allocation_limit
    end

    alter_table(:spdk_installation) do
      add_column :core_count, Integer, null: false, default: 1
      add_column :core_offset, Integer, null: false, default: 0
    end

    create_view(:vm_host_with_stats, <<~SQL
      WITH vm_stats AS (
        -- CTE to get vm stats per host. Has exactly one row per host.
        SELECT
          vm_host.id host_id,
          COALESCE(sum(cores),0) AS vm_cores,
          count(*) AS vm_count
        FROM
          vm_host LEFT OUTER JOIN vm
        ON vm_host.id=vm.vm_host_id
        GROUP BY vm_host.id
      ), spdk_stats AS (
        -- CTE to get spdk stats per host. Has exactly one row per host.
        SELECT
          vm_host.id host_id,
          COALESCE(sum(core_count),0) AS spdk_cores,
          count(*) AS spdk_count
        FROM
          vm_host LEFT OUTER JOIN spdk_installation s
        ON vm_host.id=s.vm_host_id
        GROUP BY vm_host.id
      )
      SELECT
        vm_host.*,
        vm_host.total_mem_gib / vm_host.total_cores AS mem_ratio,
        vm_count, spdk_count,
        vm_cores, spdk_cores
      FROM vm_host, vm_stats, spdk_stats
      WHERE
        vm_host.id=vm_stats.host_id AND vm_host.id=spdk_stats.host_id;
    SQL
    )
  end
end
