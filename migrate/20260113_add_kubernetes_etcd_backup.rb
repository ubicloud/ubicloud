# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_etcd_backup) do
      # UBID.to_base32_n("kb") => 619
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(619)")
      column :access_key, :text, null: false
      column :secret_key, :text, null: false
      column :latest_backup_started_at, :timestamptz

      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :kubernetes_cluster_id, :kubernetes_cluster, type: :uuid, null: false

      index :location_id
      index :kubernetes_cluster_id
    end
  end
end
