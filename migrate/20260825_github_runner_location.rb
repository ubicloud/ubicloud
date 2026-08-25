# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_runner) do
      add_foreign_key :location_id, :location, type: :uuid
    end
  end
end
