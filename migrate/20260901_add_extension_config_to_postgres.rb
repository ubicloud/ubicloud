# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      add_column :extension_config, :jsonb, null: false, default: "{}"
      add_constraint(:extension_config_root_only, Sequel.lit("parent_id IS NULL OR restore_target IS NOT NULL OR extension_config = '{}'::jsonb"))
    end
  end

  down do
    alter_table(:postgres_resource) do
      drop_constraint(:extension_config_root_only)
      drop_column :extension_config
    end
  end
end
