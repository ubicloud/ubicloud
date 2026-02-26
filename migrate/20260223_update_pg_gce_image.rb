# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_gce_image (id, gcp_project_id, gce_image_name, pg_version, arch)
      VALUES (gen_random_uuid(), 'pelagic-logic-394811', 'postgres-ubuntu-2204-x64-20260223', '18', 'x64')
      ON CONFLICT (gcp_project_id, pg_version, arch) DO NOTHING;
    SQL

    run <<~SQL
      UPDATE pg_gce_image
      SET gce_image_name = 'postgres-ubuntu-2204-x64-20260223'
      WHERE gcp_project_id = 'pelagic-logic-394811'
        AND gce_image_name = 'postgres-ubuntu-2204-x64-20260218';
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_gce_image
      WHERE gcp_project_id = 'pelagic-logic-394811'
        AND pg_version = '18';
    SQL

    run <<~SQL
      UPDATE pg_gce_image
      SET gce_image_name = 'postgres-ubuntu-2204-x64-20260218'
      WHERE gcp_project_id = 'pelagic-logic-394811'
        AND gce_image_name = 'postgres-ubuntu-2204-x64-20260223';
    SQL
  end
end
