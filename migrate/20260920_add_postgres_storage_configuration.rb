# frozen_string_literal: true

Sequel.migration do
  # The check is added unvalidated and validated separately, so the scan of
  # existing rows runs without an exclusive lock.
  no_transaction

  up do
    alter_table(:postgres_resource) do
      # Requested storage settings and plans, with application-defined fields.
      add_column :target_storage_configuration, :jsonb
      add_constraint({name: :target_storage_configuration_is_object, not_valid: true},
        Sequel.lit("target_storage_configuration IS NULL OR jsonb_typeof(target_storage_configuration) = 'object'"))
    end

    alter_table(:postgres_resource) do
      validate_constraint(:target_storage_configuration_is_object)
    end
  end

  down do
    alter_table(:postgres_resource) do
      drop_constraint(:target_storage_configuration_is_object)
      drop_column :target_storage_configuration
    end
  end
end
