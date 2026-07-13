# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:victoria_metrics_server) do
      add_column :is_representative, :boolean, null: false, default: false
    end

    run "UPDATE victoria_metrics_server SET is_representative = true"
  end

  down do
    alter_table(:victoria_metrics_server) do
      drop_column :is_representative
    end
  end
end
