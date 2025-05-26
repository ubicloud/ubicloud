# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_firewall_rule) do
      add_column :description, :text, collate: '"C"'
    end
  end
end
