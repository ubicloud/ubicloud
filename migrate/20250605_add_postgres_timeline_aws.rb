# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_foreign_key :location_id, :location, type: :uuid, null: true
    end
  end
end
