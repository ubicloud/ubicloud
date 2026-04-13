# frozen_string_literal: true

Sequel.migration do
  up do
    drop_table(:location_credential)
  end

  down do
    create_table(:location_credential) do
      column :access_key, String, collate: '"C"'
      column :secret_key, String, collate: '"C"'
      foreign_key :id, :location, type: :uuid, null: false, primary_key: true
      column :assume_role, String
    end

    run <<~SQL
      ALTER TABLE location_credential
        ADD CONSTRAINT location_credential_single_auth_mechanism CHECK (
          (access_key IS NOT NULL AND secret_key IS NOT NULL AND assume_role IS NULL)
          OR (access_key IS NULL AND secret_key IS NULL AND assume_role IS NOT NULL)
        );
    SQL

    run "INSERT INTO location_credential (id, access_key, secret_key, assume_role) SELECT id, access_key, secret_key, assume_role FROM location_credential_aws"
  end
end
