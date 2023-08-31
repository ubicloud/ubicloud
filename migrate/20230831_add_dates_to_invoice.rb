# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:invoice) do
      add_column :begin_time, :timestamptz, null: false
      add_column :end_time, :timestamptz, null: false
      add_column :status, String, collate: '"C"', null: false, default: "unpaid"
    end
  end
end
