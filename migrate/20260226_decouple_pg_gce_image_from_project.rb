# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    add_index :pg_gce_image, [:pg_version, :arch], unique: true, concurrently: true, name: :pg_gce_image_pg_version_arch_index
    drop_index :pg_gce_image, [:gcp_project_id, :pg_version, :arch], concurrently: true, name: :pg_gce_image_gcp_project_id_pg_version_arch_index
  end

  down do
    add_index :pg_gce_image, [:gcp_project_id, :pg_version, :arch], unique: true, concurrently: true, name: :pg_gce_image_gcp_project_id_pg_version_arch_index
    drop_index :pg_gce_image, [:pg_version, :arch], concurrently: true, name: :pg_gce_image_pg_version_arch_index
  end
end
