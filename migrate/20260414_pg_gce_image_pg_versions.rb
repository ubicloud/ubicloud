# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:pg_gce_image) do
      add_column :pg_versions, "text[]", collate: '"C"',
        default: Sequel.lit("ARRAY['16', '17', '18']::text[]")
    end

    run <<~SQL
      ALTER TABLE pg_gce_image ALTER COLUMN pg_versions SET NOT NULL;
      ALTER TABLE pg_gce_image ALTER COLUMN pg_versions DROP DEFAULT;
    SQL
  end

  down do
    alter_table(:pg_gce_image) do
      drop_column :pg_versions
    end
  end
end
