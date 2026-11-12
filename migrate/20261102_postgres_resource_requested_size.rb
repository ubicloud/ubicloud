# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :requested_vm_size, :text, collate: '"C"'
      add_column :requested_storage_size_gib, :bigint
    end
  end
end
