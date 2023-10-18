# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :root_cert, :text, collate: '"C"'
      add_column :root_cert_key, :text, collate: '"C"'
      add_column :server_cert, :text, collate: '"C"'
      add_column :server_cert_key, :text, collate: '"C"'
    end
  end
end
