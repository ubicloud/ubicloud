# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :github_runner, [:repository_id, :run_id, :run_attempt, :job_id], concurrently: true
  end
end
