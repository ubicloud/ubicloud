# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('gcp');"

    alter_table(:location_credential) do
      add_column :project_id, String, collate: '"C"'
      add_column :service_account_email, String, collate: '"C"'
      add_column :credentials_json, String, collate: '"C"'
    end

    run <<~SQL
      ALTER TABLE location_credential
        DROP CONSTRAINT location_credential_single_auth_mechanism,
        ADD CONSTRAINT location_credential_single_auth_mechanism CHECK (
          (
            access_key IS NOT NULL AND
            secret_key IS NOT NULL AND
            assume_role IS NULL AND
            credentials_json IS NULL
          ) OR (
            access_key IS NULL AND
            secret_key IS NULL AND
            assume_role IS NOT NULL AND
            credentials_json IS NULL
          ) OR (
            access_key IS NULL AND
            secret_key IS NULL AND
            assume_role IS NULL AND
            credentials_json IS NOT NULL AND
            project_id IS NOT NULL AND
            service_account_email IS NOT NULL
          )
        );
    SQL

    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-us-central1
        ('gcp', 'us-central1', 'gcp-us-central1', 'Iowa, US (GCP)', false, 'f5a1b2c3-d4e5-8620-a7b8-c9d0e1f2a3b4')
        ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location).where(provider: "gcp").delete

    run <<~SQL
      ALTER TABLE location_credential
        DROP CONSTRAINT location_credential_single_auth_mechanism,
        ADD CONSTRAINT location_credential_single_auth_mechanism CHECK (
          (
            access_key IS NOT NULL AND
            secret_key IS NOT NULL AND
            assume_role IS NULL
          ) OR (
            access_key IS NULL AND
            secret_key IS NULL AND
            assume_role IS NOT NULL
          )
        );
    SQL

    alter_table(:location_credential) do
      drop_column :project_id
      drop_column :service_account_email
      drop_column :credentials_json
    end

    run "DELETE FROM provider WHERE name = 'gcp';"
  end
end
