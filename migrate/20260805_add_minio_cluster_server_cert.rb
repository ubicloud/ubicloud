# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:minio_cluster) do
      add_column :server_cert, :text, collate: '"C"'
      add_column :server_cert_key, :text, collate: '"C"'
    end
  end
end
