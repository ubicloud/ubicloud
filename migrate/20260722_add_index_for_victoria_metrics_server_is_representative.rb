# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:victoria_metrics_server) do
      add_index :victoria_metrics_resource_id, unique: true, where: {is_representative: true}, concurrently: true, name: "victoria_metrics_server_resource_id_is_representative_idx"
    end
  end
end
