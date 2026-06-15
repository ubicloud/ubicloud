# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:app_process) do
      # UBID.to_base32_n("aq") => 343
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(343)")
      foreign_key :app_resource_id, :app_resource, type: :uuid, null: false
      column :process_type, :text, null: false
      column :replica_count, :integer, null: false, default: 1
      column :vm_size, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:app_resource_id, :process_type], unique: true
    end

    alter_table(:app_server) do
      add_foreign_key :app_process_id, :app_process, type: :uuid
    end
  end
end
