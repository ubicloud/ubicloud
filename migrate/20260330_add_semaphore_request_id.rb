# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:semaphore) do
      add_column :request_id, :text
      add_index :request_id, concurrently: false
    end
  end
end
