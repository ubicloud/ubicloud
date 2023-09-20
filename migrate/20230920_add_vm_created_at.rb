# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:vm_host) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
