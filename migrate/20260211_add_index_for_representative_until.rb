# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:postgres_server) do
      add_index :resource_id, unique: true, where: Sequel.~(representative_at: nil) & {representative_until: nil}, concurrently: true, name: "postgres_server_res_id_rep_at_rep_until_idx"
    end
  end

  down do
    alter_table(:postgres_server) do
      drop_index :resource_id, concurrently: true, name: "postgres_server_res_id_rep_at_rep_until_idx"
    end
  end
end
