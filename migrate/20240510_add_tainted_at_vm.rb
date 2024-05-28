# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :tainted_at, :timestamptz
    end
  end
end
