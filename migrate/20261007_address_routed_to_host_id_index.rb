# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:address) do
      add_index :routed_to_host_id, concurrently: true
    end
  end
end
