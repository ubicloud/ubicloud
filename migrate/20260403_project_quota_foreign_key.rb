# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project_quota) do
      add_foreign_key [:project_id], :project, name: :project_quota_project_id_fkey
    end
  end
end
