# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:github_runner) do
      drop_column :job_id
      drop_column :job_name
      drop_column :run_id
      drop_column :workflow_name
      drop_column :head_branch
    end
  end

  down do
    alter_table(:github_runner) do
      add_column :job_id, :bigint
      add_column :job_name, :text, collate: '"C"'
      add_column :run_id, :bigint
      add_column :workflow_name, :text, collate: '"C"'
      add_column :head_branch, :text, collate: '"C"'
    end
  end
end
