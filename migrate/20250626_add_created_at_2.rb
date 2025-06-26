# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    alter_table(:load_balancer) do
      add_column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
