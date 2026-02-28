# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:app_process) do
      # UBID.to_base32_n("ap") => 342
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(342)")
      column :group_name, :text, null: false
      column :name, :text, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :desired_count, :integer, null: false, default: 0
      column :vm_size, :text
      column :umi_id, :uuid
      column :init_script, :text
      column :init_ordinal, :integer, null: false, default: 0
      column :deploy_ordinal, :integer, null: false, default: 0
      foreign_key :private_subnet_id, :private_subnet, type: :uuid
      foreign_key :load_balancer_id, :load_balancer, type: :uuid

      unique [:project_id, :location_id, :group_name, :name]
      index :project_id
    end

    create_table(:app_process_member) do
      # UBID.to_base32_n("am") => 340
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(340)")
      foreign_key :app_process_id, :app_process, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true
      column :deploy_ordinal, :integer
      column :ordinal, :integer, null: false
      column :state, :text, null: false, default: "active"

      unique [:app_process_id, :ordinal]
      index :app_process_id
    end

    create_table(:app_release) do
      # UBID.to_base32_n("ar") => 344
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(344)")
      column :group_name, :text, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      column :release_number, :integer, null: false
      column :process_name, :text
      column :action, :text, null: false
      column :description, :text
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")

      unique [:project_id, :group_name, :release_number]
      index :project_id
    end

    create_table(:app_release_snapshot) do
      # UBID.to_base32_n("ae") => 334
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(334)")
      foreign_key :app_release_id, :app_release, type: :uuid, null: false
      foreign_key :app_process_id, :app_process, type: :uuid, null: false
      column :deploy_ordinal, :integer, null: false
      column :umi_id, :uuid
      column :init_script_hash, :text

      index :app_release_id
    end
  end

  down do
    drop_table(:app_release_snapshot)
    drop_table(:app_release)
    drop_table(:app_process_member)
    drop_table(:app_process)
  end
end
