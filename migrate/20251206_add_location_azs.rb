# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:location) do
      add_column :azs, :jsonb, null: false, default: "[]"
    end
  end
end
