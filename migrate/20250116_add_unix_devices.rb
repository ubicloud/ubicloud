# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:storage_device) do
      add_column :unix_device_list, "text[]", collate: '"C"', null: true
    end
  end
end
