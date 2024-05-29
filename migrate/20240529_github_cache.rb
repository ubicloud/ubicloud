# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_cache_entry) do
      column :id, :uuid, primary_key: true
      foreign_key :repository_id, :github_repository, type: :uuid, null: false
      column :key, :text, collate: '"C"', null: false
      column :version, :text, collate: '"C"', null: false
      column :scope, :text, collate: '"C"', null: false
      column :size, :bigint
      column :upload_id, :text, collate: '"C"', unique: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :created_by, :uuid, null: false
      column :last_accessed_at, :timestamptz
      column :last_accessed_by, :uuid
      column :committed_at, :timestamptz
      unique [:repository_id, :scope, :key, :version]
    end

    alter_table(:github_repository) do
      add_column :access_key, :text, collate: '"C"'
      add_column :secret_key, :text, collate: '"C"'
    end
  end
end
