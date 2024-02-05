# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_cluster) do
      add_column :root_cert_1, :text, collate: '"C"'
      add_column :root_cert_key_1, :text, collate: '"C"'
      add_column :root_cert_2, :text, collate: '"C"'
      add_column :root_cert_key_2, :text, collate: '"C"'
      add_column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    alter_table(:minio_server) do
      add_column :cert, :text, collate: '"C"'
      add_column :cert_key, :text, collate: '"C"'
      add_column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
