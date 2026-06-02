# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      set_column_type :hostname_version, :text, using: Sequel.cast(:hostname_version, :text)
      set_column_default :hostname_version, "v1"
      add_constraint :hostname_version_check, hostname_version: %w[v1 v2 v3]
    end

    drop_enum(:hostname_version)

    create_table(:presigned_postgres_cert) do
      uuid :postgres_resource_id, primary_key: true # deliberately not foreign key
      foreign_key :cert_id, :cert, type: :uuid, null: false, unique: true
      timestamptz :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP, index: true
    end
  end

  down do
    drop_table(:presigned_postgres_cert)

    create_enum(:hostname_version, %w[v1 v2])

    alter_table(:postgres_resource) do
      drop_constraint :hostname_version_check
      set_column_default :hostname_version, nil
    end

    alter_table(:postgres_resource) do
      set_column_type :hostname_version, :hostname_version, using: Sequel.cast(:hostname_version, :hostname_version)
      set_column_default :hostname_version, Sequel.cast("v1", :hostname_version)
    end
  end
end
