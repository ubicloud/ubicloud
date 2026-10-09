# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:usage_alert) do
      add_index :user_id, concurrently: true
    end
  end
end
