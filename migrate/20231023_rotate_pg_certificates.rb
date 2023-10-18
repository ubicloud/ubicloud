# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :root_cert_2, :text, collate: '"C"'
      add_column :root_cert_key_2, :text, collate: '"C"'
      add_column :certificate_last_checked_at, :timestamptz, null: false, default: Sequel.lit("now()")
      rename_column :root_cert, :root_cert_1
      rename_column :root_cert_key, :root_cert_key_1
    end
  end

  down do
    alter_table(:postgres_server) do
      drop_column :root_cert_2
      drop_column :root_cert_key_2
      drop_column :certificate_last_checked_at
      rename_column :root_cert_1, :root_cert
      rename_column :root_cert_key_1, :root_cert_key
    end
  end
end
