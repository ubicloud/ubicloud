# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:kubernetes_etcd_backup) do
      add_column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    run "UPDATE kubernetes_etcd_backup SET created_at = kc.created_at FROM kubernetes_cluster kc WHERE kubernetes_etcd_backup.kubernetes_cluster_id = kc.id"
  end

  down do
    alter_table(:kubernetes_etcd_backup) do
      drop_column :created_at
    end
  end
end
