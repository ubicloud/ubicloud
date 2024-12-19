Sequel.migration do
  change do
    alter_table(:vm_host_slice) do
      add_column :total_memory_gib, Integer, null: true
      add_column :used_memory_gib, Integer, null: true
    end
  end
end
