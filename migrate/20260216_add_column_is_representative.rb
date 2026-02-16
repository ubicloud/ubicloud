# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :is_representative, :boolean, null: false, default: false
    end

    run "UPDATE postgres_server SET is_representative = true WHERE representative_at IS NOT NULL"
  end

  down do
    alter_table(:postgres_server) do
      drop_column :is_representative
    end
  end
end
