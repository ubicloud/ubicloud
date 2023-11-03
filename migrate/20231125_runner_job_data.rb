# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_column :workflow_job, :jsonb
    end
  end
end
