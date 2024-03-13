# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :allocated_at, :timestamptz
      add_column :provisioned_at, :timestamptz
    end
  end
end
