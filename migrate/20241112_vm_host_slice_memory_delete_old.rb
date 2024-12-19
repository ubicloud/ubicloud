Sequel.migration do
  change do
    alter_table(:vm_host_slice) do
      drop_column :total_memory_1g
      drop_column :used_memory_1g
    end
  end
end
