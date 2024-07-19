# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:project_quota) do
      column :project_id, :uuid, null: false
      column :quota_id, :uuid, null: false
      column :value, :integer, null: false
      primary_key [:project_id, :quota_id]
    end

    run "INSERT INTO project_quota (SELECT id, '14fa6820-bf63-41d2-b35e-4a4dcefd1b15', runner_core_limit FROM project WHERE runner_core_limit != 150)"
  end

  down do
    drop_table(:project_quota)
  end
end
