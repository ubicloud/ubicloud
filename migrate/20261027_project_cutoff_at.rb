# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :cutoff_at, Time
    end
  end
end
