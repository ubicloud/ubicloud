# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:accounts) do
      add_column :suspended_at, :timestamptz
    end
  end
end
