# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:kubernetes_nodepool) do
      add_unique_constraint [:kubernetes_cluster_id, :name], name: :kubernetes_nodepool_kubernetes_cluster_id_name_key
    end
  end

  down do
    alter_table(:kubernetes_nodepool) do
      drop_constraint :kubernetes_nodepool_kubernetes_cluster_id_name_key
    end
  end
end
