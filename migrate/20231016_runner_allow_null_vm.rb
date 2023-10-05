# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      set_column_allow_null :vm_id
    end
  end
end
