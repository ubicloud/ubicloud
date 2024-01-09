# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:minio_pool) do
      add_column :vm_size, :text, collate: '"C"'
    end

    run <<~SQL
      UPDATE minio_pool SET vm_size = 'standard-2';
    SQL

    alter_table(:minio_pool) do
      set_column_not_null :vm_size
    end
  end

  down do
    alter_table(:minio_pool) do
      drop_column :vm_size
    end
  end
end
