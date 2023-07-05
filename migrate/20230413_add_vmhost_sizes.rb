# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :total_mem_gib, Integer

      # Standardize on lscpu nomenclature. "cpus" may also be
      # "threads," "nodes" seems to closest to "dies."  "Socket" could
      # also be rendered "package." "core" has no terminological
      # variants.
      add_column :total_sockets, Integer
      add_column :total_nodes, Integer
      add_column :total_cores, Integer
      add_column :total_cpus, Integer
    end
  end
end
