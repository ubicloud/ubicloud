# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      drop_constraint(:target_version_check)
      add_constraint(:target_version_check, Sequel.lit("target_version IN ('16', '17', '18')"))
    end

    alter_table(:postgres_server) do
      drop_constraint(:version_check)
      add_constraint(:version_check, Sequel.lit("version IN ('16', '17', '18')"))
    end
  end

  down do
    alter_table(:postgres_resource) do
      drop_constraint(:target_version_check)
      add_constraint(:target_version_check, Sequel.lit("target_version IN ('16', '17')"))
    end

    alter_table(:postgres_server) do
      drop_constraint(:version_check)
      add_constraint(:version_check, Sequel.lit("version IN ('16', '17')"))
    end
  end
end
