# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_pool) do
      add_column :vm_size, :text, collate: '"C"', null: false
    end
  end
end
