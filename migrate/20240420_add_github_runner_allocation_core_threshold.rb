# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :github_runner_allocation_core_threshold, :int, default: 0, null: false
    end
  end
end
