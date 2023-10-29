# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_pool) do
      add_column :storage_size_gib, :bigint
    end

    run <<~SQL
      UPDATE vm_pool SET storage_size_gib = CASE
          WHEN vm_size = 'standard-2' THEN 86
          WHEN vm_size = 'standard-4' THEN 150
          WHEN vm_size = 'standard-8' THEN 200
          WHEN vm_size = 'standard-16' THEN 300
          ELSE storage_size_gib END
      WHERE location = 'github-runners';
    SQL

    alter_table(:vm_pool) do
      set_column_not_null :storage_size_gib
    end
  end

  down do
    alter_table(:vm_pool) do
      drop_column :storage_size_gib
    end
  end
end
