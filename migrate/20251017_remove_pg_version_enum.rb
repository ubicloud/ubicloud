# frozen_string_literal: true

Sequel.migration do
  up do
    # Add temporary VARCHAR columns
    alter_table(:postgres_resource) do
      add_column :target_version_new, String, collate: '"C"'
    end

    alter_table(:postgres_server) do
      add_column :version_new, String, collate: '"C"'
    end

    # Copy data from enum columns to new columns
    run "UPDATE postgres_resource SET target_version_new = target_version::text"
    run "UPDATE postgres_server SET version_new = version::text"

    # Drop old enum columns
    alter_table(:postgres_resource) do
      drop_column :target_version
    end

    alter_table(:postgres_server) do
      drop_column :version
    end

    # Rename new columns
    alter_table(:postgres_resource) do
      rename_column :target_version_new, :target_version
    end

    alter_table(:postgres_server) do
      rename_column :version_new, :version
    end

    # Add CHECK constraints
    alter_table(:postgres_resource) do
      add_constraint(:target_version_check, Sequel.lit("target_version IN ('16', '17')"))
      set_column_not_null :target_version
    end

    alter_table(:postgres_server) do
      add_constraint(:version_check, Sequel.lit("version IN ('16', '17')"))
      set_column_not_null :version
    end

    # Drop the enum type
    run "DROP TYPE postgres_version"
  end

  down do
    # Recreate enum type
    create_enum(:postgres_version, %w[16 17])

    # Add temporary enum columns
    alter_table(:postgres_resource) do
      add_column :target_version_enum, :postgres_version
    end

    alter_table(:postgres_server) do
      add_column :version_enum, :postgres_version
    end

    # Copy data back
    run "UPDATE postgres_resource SET target_version_enum = target_version::postgres_version"
    run "UPDATE postgres_server SET version_enum = version::postgres_version"

    # Drop CHECK constrained columns
    alter_table(:postgres_resource) do
      drop_constraint(:target_version_check)
      set_column_not_null :target_version
      drop_column :target_version
    end

    alter_table(:postgres_server) do
      drop_constraint(:version_check)
      set_column_not_null :version
      drop_column :version
    end

    # Rename enum columns back
    alter_table(:postgres_resource) do
      rename_column :target_version_enum, :target_version
    end

    alter_table(:postgres_server) do
      rename_column :version_enum, :version
    end
  end
end
