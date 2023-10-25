# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:page) do
      add_column :details, :jsonb, null: false, default: "{}"
    end
  end
end
