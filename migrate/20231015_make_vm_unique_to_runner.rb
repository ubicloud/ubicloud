# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_unique_constraint :vm_id
    end
  end
end
