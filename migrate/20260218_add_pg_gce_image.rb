# frozen_string_literal: true

Sequel.migration do
  up do
    # No location column. GCE images are project-global resources (the path
    # contains "global" by design), so a single image row applies to every
    # GCP location that uses the same hosting project.
    create_table(:pg_gce_image) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # UBID.to_base32_n("et") => 474
      column :gce_image_name, :text, null: false
      column :arch, :text, null: false

      index [:arch, :gce_image_name], unique: true
    end

    # Hard-coded because these are externally-built GCE images for Postgres VMs.
    # They are built outside of this codebase and change infrequently, so we
    # seed them via migration rather than a runtime registration process.
    # The hosting project id lives in Config (postgres_gce_image_gcp_project_id),
    # not in the table, because it is configuration rather than data.
    run <<~SQL
      INSERT INTO pg_gce_image (id, gce_image_name, arch) VALUES
        /* ubid 0ktm6pew48zs6nt96fv453k0gz */
        ('d50d6770-88fe-4c13-ae92-67ec851cc10f', 'postgres-ubuntu-2204-x64-20260223', 'x64'),
        /* ubid z1r54160ag6h2jqmv7jsz0c9bf */
        ('c1481301-5034-47e1-95e9-b3cb3f0312b7', 'postgres-ubuntu-2204-arm64-20260225', 'arm64')
    SQL
  end

  down do
    drop_table(:pg_gce_image)
  end
end
