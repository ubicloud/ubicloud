# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:pg_gce_image) do
      column :id, :uuid, primary_key: true
      column :gcp_project_id, :text, null: false
      column :gce_image_name, :text, null: false
      column :arch, :text, null: false, unique: true
    end

    run <<~SQL
      INSERT INTO pg_gce_image (id, gcp_project_id, gce_image_name, arch) VALUES
        ('d50d6770-88fe-4c13-ae92-67ec851cc10f', 'pelagic-logic-394811', 'postgres-ubuntu-2204-x64-20260223', 'x64'),
        ('c1481301-5034-47e1-95e9-b3cb3f0312b7', 'pelagic-logic-394811', 'postgres-ubuntu-2204-arm64-20260225', 'arm64')
    SQL
  end

  down do
    drop_table(:pg_gce_image)
  end
end
