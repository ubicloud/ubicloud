# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO vm_host_cpu (vm_host_id, cpu_number, spdk, vm_host_slice_id)
      WITH t AS (
          SELECT
              vm_host.id AS vm_host_id,
              generate_series(0, total_cpus-1) AS cpu_number,
              MAX(spdk_installation.cpu_count) AS spdk_cpus
          FROM
              vm_host
          JOIN
              spdk_installation ON vm_host.id = spdk_installation.vm_host_id
          GROUP BY
              vm_host.id
      )
      SELECT
          vm_host_id,
          cpu_number,
          cpu_number < spdk_cpus,
          NULL
      FROM
          t
      ON CONFLICT (vm_host_id, cpu_number) DO NOTHING;
    SQL
  end
end
