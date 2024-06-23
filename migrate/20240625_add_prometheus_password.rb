# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :prometheus_password, :text, collate: '"C"'
    end
  end
end
