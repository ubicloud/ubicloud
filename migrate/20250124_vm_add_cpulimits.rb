# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :cpu_percent_limit, :integer, null: true
      add_column :cpu_burst_percent_limit, :integer, null: true
    end
  end
end
