# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :billable, :boolean, null: false, default: true
    end
  end
end
