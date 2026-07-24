# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      add_column :desired_extensions, :jsonb, null: false, default: "{}"
      add_column :extension_config, :jsonb, null: false, default: "{}"
      add_constraint(:desired_extensions_root_only, Sequel.lit("parent_id IS NULL OR restore_target IS NOT NULL OR desired_extensions = '{}'::jsonb"))
      add_constraint(:extension_config_root_only, Sequel.lit("parent_id IS NULL OR restore_target IS NOT NULL OR extension_config = '{}'::jsonb"))
    end

    create_table(:postgres_server_extension) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(733)") # UBID.to_base32_n("px") => 733
      foreign_key :postgres_server_id, :postgres_server, type: :uuid, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :target_version, :text
      column :installed_version, :text
      column :state, :text, null: false, default: "install_pending"
      DateTime :last_transition_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_error, :text
      unique [:postgres_server_id, :name]
      constraint(:postgres_server_extension_state_check, Sequel.lit("state IN ('install_pending', 'installing', 'sync_pending', 'config_pending', 'restart_pending', 'verifying', 'ready', 'failed')"))
    end
  end

  down do
    alter_table(:postgres_resource) do
      drop_constraint(:desired_extensions_root_only)
      drop_constraint(:extension_config_root_only)
      drop_column :desired_extensions
      drop_column :extension_config
    end

    drop_table(:postgres_server_extension)
  end
end
