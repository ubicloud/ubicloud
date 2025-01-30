# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_nodepool) do
      add_column(:target_node_size, :text, collate: '"C"', null: false)
      add_column(:target_node_storage_size_gib, :bigint, null: true)
    end

    alter_table(:kubernetes_cluster) do
      add_column(:target_node_size, :text, collate: '"C"', null: false)
      add_column(:target_node_storage_size_gib, :bigint, null: true)
    end
  end
end
