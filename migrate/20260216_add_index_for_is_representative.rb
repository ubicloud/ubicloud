# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:postgres_server) do
      add_index :resource_id, unique: true, where: {is_representative: true}, concurrently: true, name: "postgres_server_resource_id_is_representative_idx"
    end
  end
end
