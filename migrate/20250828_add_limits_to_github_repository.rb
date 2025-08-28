# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_repository) do
      add_column :limits, :jsonb, default: Sequel.pg_jsonb({})
    end
  end
end
