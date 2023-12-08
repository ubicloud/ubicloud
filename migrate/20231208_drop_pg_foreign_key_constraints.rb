# frozen_string_literal: true

Sequel.migration do
  # When column names are passed in array form, Sequel only drops or creates
  # the constraint, without touching to the column itself.
  up do
    alter_table(:postgres_resource) do
      drop_foreign_key [:parent_id]
    end

    alter_table(:postgres_timeline) do
      drop_foreign_key [:parent_id]
    end
  end

  down do
    alter_table(:postgres_resource) do
      add_foreign_key([:parent_id], :postgres_resource)
    end

    alter_table(:postgres_timeline) do
      add_foreign_key([:parent_id], :postgres_timeline)
    end
  end
end
