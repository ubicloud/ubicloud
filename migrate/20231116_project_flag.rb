# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :feature_flags, :jsonb, null: false, default: "{}"
    end
  end
end
