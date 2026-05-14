# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:load_balancer) do
      add_column :hostname_version, Integer, default: 1, null: false
      add_constraint :hostname_version_check, hostname_version: [1, 2]
    end
  end
end
