# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_gce_image (id, gcp_project_id, gce_image_name, pg_version, arch)
      VALUES
        (gen_random_uuid(), 'pelagic-logic-394811', 'postgres-ubuntu-2204-arm64-20260225', '16', 'arm64'),
        (gen_random_uuid(), 'pelagic-logic-394811', 'postgres-ubuntu-2204-arm64-20260225', '17', 'arm64'),
        (gen_random_uuid(), 'pelagic-logic-394811', 'postgres-ubuntu-2204-arm64-20260225', '18', 'arm64')
      ON CONFLICT (gcp_project_id, pg_version, arch) DO NOTHING;
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_gce_image
      WHERE gcp_project_id = 'pelagic-logic-394811'
        AND arch = 'arm64';
    SQL
  end
end
