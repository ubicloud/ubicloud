# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_server) do
      add_column :current_io_throttle_mbps, :integer, null: true, default: nil
    end
  end
end
