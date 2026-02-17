# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('gcp');"

    create_table(:location_credential_gcp) do
      foreign_key :id, :location, type: :uuid, null: false, primary_key: true
      column :project_id, String, null: false, collate: '"C"'
      column :service_account_email, String, null: false, collate: '"C"'
      column :credentials_json, String, null: false, collate: '"C"'
    end

    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-us-central1
        ('gcp', 'us-central1', 'gcp-us-central1', 'Iowa, US (GCP)', false, 'f5a1b2c3-d4e5-8620-a7b8-c9d0e1f2a3b4')
        ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    from(:location).where(provider: "gcp").delete
    drop_table(:location_credential_gcp)
    run "DELETE FROM provider WHERE name = 'gcp';"
  end
end
