# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :backup_inprogress_server_id, :uuid
    end
  end
end
