# frozen_string_literal: true

Sequel.migration do
  up do
    # UBID.to_base32_n("nt") => 698
    create_table(:init_script_tag) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(698)")
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, :text, null: false
      column :version, :integer, null: false
      column :init_script, :text, null: false
      column :description, :text
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      unique [:project_id, :name, :version]
      index :project_id
    end

    # UBID.to_base32_n("a0") => 320
    create_table(:app_process_init) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(320)")
      foreign_key :app_process_id, :app_process, type: :uuid, null: false
      foreign_key :init_script_tag_id, :init_script_tag, type: :uuid, null: false
      column :ordinal, :integer, null: false

      unique [:app_process_id, :init_script_tag_id]
      unique [:app_process_id, :ordinal]
      index :app_process_id
    end

    # UBID.to_base32_n("m0") => 640
    create_table(:app_member_init) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(640)")
      foreign_key :app_process_member_id, :app_process_member, type: :uuid, null: false
      foreign_key :init_script_tag_id, :init_script_tag, type: :uuid, null: false

      unique [:app_process_member_id, :init_script_tag_id]
      index :app_process_member_id
    end

    # UBID.to_base32_n("r1") => 769
    create_table(:app_release_snapshot_init) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(769)")
      foreign_key :app_release_snapshot_id, :app_release_snapshot, type: :uuid, null: false
      foreign_key :init_script_tag_id, :init_script_tag, type: :uuid, null: false

      unique [:app_release_snapshot_id, :init_script_tag_id]
      index :app_release_snapshot_id
    end

    # Remove v1 columns from app_process
    alter_table(:app_process) do
      drop_constraint :app_process_load_balancer_id_fkey
      drop_column :load_balancer_id
      drop_column :init_script
      drop_column :init_ordinal
      drop_column :deploy_ordinal
    end
  end

  down do
    alter_table(:app_process) do
      add_column :init_script, :text
      add_column :init_ordinal, :integer, null: false, default: 0
      add_column :deploy_ordinal, :integer, null: false, default: 0
      add_column :load_balancer_id, :uuid
      add_foreign_key [:load_balancer_id], :load_balancer
    end

    drop_table(:app_release_snapshot_init)
    drop_table(:app_member_init)
    drop_table(:app_process_init)
    drop_table(:init_script_tag)
  end
end
