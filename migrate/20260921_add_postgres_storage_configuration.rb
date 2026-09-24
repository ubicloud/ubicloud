# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :target_storage_configuration, :jsonb
      add_constraint({name: :target_storage_configuration_is_object, not_valid: true},
        Sequel.lit("target_storage_configuration IS NULL OR jsonb_typeof(target_storage_configuration) = 'object'"))
    end
  end
end
