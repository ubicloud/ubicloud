# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:semaphore) do
      add_column :request_ids, "text[]"
      add_index :request_ids, concurrently: false, using: "hash"
    end
  end
end
