# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_repository) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :installation_id, :github_installation, type: :uuid
      column :name, :text, collate: '"C"', null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_job_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_check_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      index [:installation_id, :name], unique: true
    end

    alter_table(:github_runner) do
      add_foreign_key :repository_id, :github_repository, type: :uuid
    end
  end
end
