# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE kubernetes_nodepool
      SET version = (
        SELECT version FROM kubernetes_cluster
        WHERE kubernetes_cluster.id = kubernetes_nodepool.kubernetes_cluster_id
      )
      WHERE version IS NULL
    SQL

    alter_table(:kubernetes_nodepool) do
      set_column_not_null :version
    end
  end

  down do
    alter_table(:kubernetes_nodepool) do
      set_column_allow_null :version
    end
  end
end
