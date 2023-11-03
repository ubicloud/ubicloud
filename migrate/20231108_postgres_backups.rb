# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:timeline_access, %w[push fetch])

    alter_table(:postgres_timeline) do
      add_column :last_backup_started_at, :timestamptz
      add_column :last_ineffective_check_at, :timestamptz
    end

    alter_table(:postgres_server) do
      add_foreign_key :timeline_id, :postgres_timeline, type: :uuid, null: false
      add_column :timeline_access, :timeline_access, null: false, default: "push"
    end
  end
end
