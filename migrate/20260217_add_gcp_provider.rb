# frozen_string_literal: true

Sequel.migration do
  up do
    from(:provider).insert(name: "gcp")

    create_table(:location_credential_gcp) do
      foreign_key :id, :location, type: :uuid, primary_key: true
      column :project_id, String, null: false, collate: '"C"'
      column :service_account_email, String, null: false, collate: '"C"'
      column :credentials_json, String, null: false, collate: '"C"'
    end

    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-us-central1 (UBID: 10mawew6axw21p8ay536s87h5g)
        ('gcp', 'us-central1', 'gcp-us-central1', 'Iowa, US (GCP)', false, 'a2b8ee19-5de0-8020-b215-e28cd941e258');
    SQL
  end

  down do
    from(:location).where(provider: "gcp").delete

    drop_table(:location_credential_gcp)

    from(:provider).where(name: "gcp").delete
  end
end
