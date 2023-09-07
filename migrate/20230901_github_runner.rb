# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_installation) do
      column :id, :uuid, primary_key: true, default: nil
      column :installation_id, :bigint, null: false
      column :name, :text, collate: '"C"', null: false
      column :type, :text, collate: '"C"', null: false
      foreign_key :project_id, :project, type: :uuid
    end

    create_table(:github_runner) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :installation_id, :github_installation, type: :uuid
      column :repository_name, :text, collate: '"C"', null: false
      column :label, :text, collate: '"C"', null: false
      column :vm_id, :uuid, null: false
      column :runner_id, :bigint
      column :job_id, :bigint
      column :job_name, :text, collate: '"C"'
      column :run_id, :bigint
      column :workflow_name, :text, collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :ready_at, :timestamptz
    end
  end
end
