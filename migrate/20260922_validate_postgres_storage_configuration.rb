# frozen_string_literal: true

Sequel.migration do
  # Validate the NOT VALID object check in a separate migration so the scan
  # of existing rows takes no exclusive lock.
  no_transaction

  up do
    alter_table(:postgres_resource) do
      validate_constraint(:target_storage_configuration_is_object)
    end
  end

  # Postgres cannot mark a validated constraint NOT VALID again. Rolling back
  # the migration that adds the constraint drops it.
  down do
  end
end
