# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:project) do
      drop_column :runner_core_limit
    end
  end

  down do
    alter_table(:project) do
      add_column :runner_core_limit, Integer, default: 150, null: false
    end

    run "UPDATE project SET runner_core_limit = project_quota.value FROM project_quota WHERE project.id = project_quota.project_id AND project_quota.quota_id = '14fa6820-bf63-41d2-b35e-4a4dcefd1b15'"
  end
end
