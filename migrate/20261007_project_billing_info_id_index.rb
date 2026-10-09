# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:project) do
      add_index :billing_info_id, concurrently: true
    end
  end
end
