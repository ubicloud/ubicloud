# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:postgres_migration_status, %w[
      accepting_connection_info
      preparing_client_vm
      discovering
      plan_ready
      creating_target
      migrating
      verifying
      completed
      failed
      cancelled
    ])

    create_enum(:postgres_migration_database_status, %w[
      pending
      migrating
      completed
      failed
      skipped
    ])

    create_table(:postgres_migration) do
      # UBID.to_base32_n("p8") => 712
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(712)")
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :target_resource_id, :postgres_resource, type: :uuid, null: true
      foreign_key :vm_id, :vm, type: :uuid, null: true
      foreign_key :location_id, :location, type: :uuid, null: true

      column :source_connection_string, :text, null: true
      column :source_host, :text, null: true
      column :source_port, :integer, null: true, default: 5432
      column :source_user, :text, null: true
      column :source_password, :text, null: true
      column :source_database, :text, null: true

      column :status, :postgres_migration_status, null: false, default: "accepting_connection_info"

      column :discovered_metadata, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")

      column :selected_region, :text, null: true
      column :selected_vm_size, :text, null: true
      column :selected_storage_size_gib, :bigint, null: true
      column :selected_pg_version, :text, null: true

      column :discovery_completed_at, :timestamptz, null: true
      column :migration_started_at, :timestamptz, null: true
      column :completed_at, :timestamptz, null: true

      index :project_id
    end

    create_table(:postgres_migration_database) do
      # UBID.to_base32_n("p9") => 713
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(713)")
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")

      foreign_key :postgres_migration_id, :postgres_migration, type: :uuid, null: false

      column :name, :text, null: false
      column :size_bytes, :bigint, null: true
      column :table_count, :integer, null: true
      column :selected, :boolean, null: false, default: true
      column :migration_status, :postgres_migration_database_status, null: false, default: "pending"
      column :error_message, :text, null: true
      column :started_at, :timestamptz, null: true
      column :completed_at, :timestamptz, null: true

      index :postgres_migration_id
    end
  end
end
