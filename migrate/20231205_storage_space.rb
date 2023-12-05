# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :storage_space, :text, null: false, default: "DEFAULT"
    end
  end
end
