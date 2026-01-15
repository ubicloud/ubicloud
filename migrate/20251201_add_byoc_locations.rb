# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:location) do
      add_column :byoc, :boolean, null: false, default: false
    end
  end
end
