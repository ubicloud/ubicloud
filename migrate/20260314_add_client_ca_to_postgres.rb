# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      add_column :client_root_cert_1, :text
      add_column :client_root_cert_key_1, :text
      add_column :client_root_cert_2, :text
      add_column :client_root_cert_key_2, :text
      add_column :client_cert, :text
      add_column :client_cert_key, :text
    end

    # For existing databases, use the same CA roots for client and server
    run <<~SQL
      UPDATE postgres_resource
      SET client_root_cert_1 = root_cert_1,
          client_root_cert_key_1 = root_cert_key_1,
          client_root_cert_2 = root_cert_2,
          client_root_cert_key_2 = root_cert_key_2,
          client_cert = server_cert,
          client_cert_key = server_cert_key
    SQL
  end

  down do
    alter_table(:postgres_resource) do
      drop_column :client_root_cert_1
      drop_column :client_root_cert_key_1
      drop_column :client_root_cert_2
      drop_column :client_root_cert_key_2
      drop_column :client_cert
      drop_column :client_cert_key
    end
  end
end
